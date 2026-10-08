defmodule GSMLG.Web.AgentNoteServicesTest do
  use GSMLG.Web.ConnCase, async: false
  import Ecto.Query
  import GSMLG.AccountsFixtures
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Compat.Search

  defmodule ServiceStub do
    import Phoenix.ConnTest, except: [get: 2, post: 2]
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    post "/search" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(Process.whereis(:gaonote_services_test), {:search, Jason.decode!(body)})
      hits = Application.get_env(:gsmlg_web, :gaonote_search_test_hits)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(hits))
    end

    post "/index" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      send(
        Process.whereis(:gaonote_services_test),
        {:index, request, Plug.Conn.get_req_header(conn, "idempotency-key")}
      )

      response = %{
        request_id: request["request_id"],
        note_id: request["note"]["id"],
        updated_at: request["note"]["updated_at"],
        status: "accepted"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(response))
    end

    post "/forms/chromium/convert/html" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(Process.whereis(:gaonote_services_test), {:pdf_package, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/pdf")
      |> send_resp(200, "%PDF-1.7\nfixture\n%%EOF")
    end
  end

  setup do
    Process.register(self(), :gaonote_services_test)
    previous = Application.fetch_env(:gsmlg_gao_note, :compat_services)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    start_supervised!({Bandit, plug: ServiceStub, port: port, startup_log: false})
    base = "http://127.0.0.1:#{port}"

    Application.put_env(:gsmlg_gao_note, :compat_services,
      search_url: base <> "/search",
      pdf_renderer_url: base,
      minimum_score: 0.01
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gsmlg_gao_note, :compat_services, value)
        :error -> Application.delete_env(:gsmlg_gao_note, :compat_services)
      end

      Application.delete_env(:gsmlg_web, :gaonote_search_test_hits)
    end)

    :ok
  end

  test "search returns external scores, drops missing/stale-deleted hits, and applies minimum score" do
    {:ok, note} = GaoNote.create_note(%{title: "Hit", content: "body"}, nil)

    Application.put_env(:gsmlg_web, :gaonote_search_test_hits, [
      %{id: note.id, score: 0.02},
      %{id: note.id, score: 0.001},
      %{id: Ecto.UUID.generate(), score: 0.5}
    ])

    assert {:ok, [%{note: hit, score: 0.02}]} =
             Search.search_notes(%{query: "meaning", limit: 10})

    assert hit.id == note.id
    assert_receive {:search, %{"query" => "meaning", "limit" => 10, "label" => ""}}

    assert {:error, {:invalid_input, _}} =
             Search.search_notes(%{query: "meaning", limit: 10, label: "~bad"})
  end

  test "index delivery follows the external contract and includes no attachment bytes" do
    config = Search.config()
    index_url = String.replace(config[:search_url], "/search", "/index")

    Application.put_env(
      :gsmlg_gao_note,
      :compat_services,
      Keyword.put(config, :index_url, index_url)
    )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, note} = GaoNote.create_note(%{title: "Index", content: "Markdown"}, nil)

      assert [%Oban.Job{} = job] =
               GSMLG.Repo.all(
                 from(j in Oban.Job, where: j.worker == "GSMLG.GaoNote.Workers.IndexWorker")
               )

      assert :ok = GSMLG.GaoNote.Workers.IndexWorker.perform(job)

      assert_receive {:index,
                      %{
                        "note" => payload,
                        "embedding" => %{"model" => "BAAI/bge-m3"},
                        "chunking" => %{"profile" => "bge-m3-markdown-v1"}
                      }, [key]}

      assert payload["id"] == note.id
      assert payload["content"] == "Markdown"
      refute Map.has_key?(payload, "attachments")
      assert key == "gao-note:#{note.id}:#{DateTime.to_iso8601(note.updated_at)}"
    end)
  end

  test "PDF packages a saved revision and checks stale requests before calling renderer" do
    {:ok, note} =
      GaoNote.create_note(%{title: "PDF", content: "# Saved\n<script>bad()</script>"}, nil)

    conn = get(authenticated_conn(), "/api/notes/#{note.id}/export/pdf?expected_revision=1")
    assert response(conn, 200) =~ "%PDF-1.7"
    assert get_resp_header(conn, "x-note-revision") == ["1"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert_receive {:pdf_package, body}
    assert body =~ "index.html"
    assert body =~ "<h1>Saved</h1>"
    refute body =~ "<script>"
    {:ok, _} = GaoNote.update_note_fields(note, %{title: "Changed"}, nil)

    assert %{"code" => "stale_revision"} =
             authenticated_conn()
             |> get("/api/notes/#{note.id}/export/pdf?expected_revision=1")
             |> json_response(409)

    refute_receive {:pdf_package, _}
  end

  test "unexpected renderer task failures return a bounded error and release capacity" do
    services = Application.fetch_env!(:gsmlg_gao_note, :compat_services)

    Application.put_env(
      :gsmlg_gao_note,
      :compat_services,
      Keyword.put(services, :pdf_renderer_url, "invalid://renderer")
    )

    {:ok, note} = GaoNote.create_note(%{title: "Crash", content: "Body"}, nil)
    conn = get(authenticated_conn(), "/api/notes/#{note.id}/export/pdf?expected_revision=1")
    assert %{"retryable" => true} = json_response(conn, 503)
    assert {:ok, first} = GSMLG.Web.AgentNotePDFPool.acquire()
    assert {:ok, second} = GSMLG.Web.AgentNotePDFPool.acquire()
    GSMLG.Web.AgentNotePDFPool.release(first)
    GSMLG.Web.AgentNotePDFPool.release(second)
  end

  test "export capacity rejects excess requests without invoking renderer" do
    {:ok, first} = GSMLG.Web.AgentNotePDFPool.acquire()
    {:ok, second} = GSMLG.Web.AgentNotePDFPool.acquire()

    try do
      conn =
        get(
          authenticated_conn(),
          "/api/notes/#{Ecto.UUID.generate()}/export/pdf?expected_revision=1"
        )

      assert %{"code" => "export_busy", "retryable" => true} = json_response(conn, 429)
      assert get_resp_header(conn, "retry-after") == ["2"]
      refute_receive {:pdf_package, _}
    after
      GSMLG.Web.AgentNotePDFPool.release(first)
      GSMLG.Web.AgentNotePDFPool.release(second)
    end
  end

  defp authenticated_conn do
    user =
      user_fixture(%{
        email: "gaonote-#{System.unique_integer([:positive])}@test",
        username: "gaonote_#{System.unique_integer([:positive])}"
      })

    {:ok, token, _} = GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "access")
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
