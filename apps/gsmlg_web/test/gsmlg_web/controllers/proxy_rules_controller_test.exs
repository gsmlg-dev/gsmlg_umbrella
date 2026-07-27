defmodule GSMLG.Web.ProxyRulesControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.ProxyRules.{Compiler, Configuration, Snapshot, Store}

  @compiled_at ~U[2026-07-23 01:02:03Z]

  setup tags do
    prior = Store.current()
    snapshot = fixture_snapshot()

    replace_current(if(tags[:empty_store], do: nil, else: snapshot))

    on_exit(fn ->
      case prior do
        {:ok, prior_snapshot} -> replace_current(prior_snapshot)
        {:error, :not_ready} -> replace_current(nil)
      end
    end)

    {:ok, snapshot: snapshot}
  end

  for {list_path, list} <- [{"proxy-list", :proxy}, {"direct-list", :direct}],
      {format_path, format} <- [{"raw", :raw}, {"squid", :squid}, {"clash", :clash}] do
    test "serves #{list_path}/#{format_path} with immutable metadata", %{
      conn: conn,
      snapshot: snapshot
    } do
      list = unquote(list)
      format = unquote(format)
      output = snapshot.rendered_outputs[list][format]

      conn = get(conn, "/api/proxy-rules/#{unquote(list_path)}/#{unquote(format_path)}")

      assert response(conn, 200) == output.body
      assert get_resp_header(conn, "etag") == [output.etag]
      assert get_resp_header(conn, "last-modified") == [http_date(output.last_modified)]
      assert get_resp_header(conn, "cache-control") == [cache_control()]
      assert get_resp_header(conn, "content-length") == [to_string(output.content_length)]
      assert get_resp_header(conn, "content-type") == [output.content_type]
      assert get_resp_header(conn, "x-proxy-rules-generation") == ["12"]
    end
  end

  test "returns 304 for a comma-separated weak matching ETag", %{
    conn: conn,
    snapshot: snapshot
  } do
    output = snapshot.rendered_outputs.proxy.raw

    conn =
      conn
      |> put_req_header("if-none-match", ~s("other", W/#{output.etag}, "later"))
      |> get("/api/proxy-rules/proxy-list/raw")

    assert response(conn, 304) == ""
    assert get_resp_header(conn, "etag") == [output.etag]
    assert get_resp_header(conn, "last-modified") == [http_date(output.last_modified)]
    assert get_resp_header(conn, "cache-control") == [cache_control()]
    assert get_resp_header(conn, "x-proxy-rules-generation") == ["12"]
  end

  test "returns 304 when If-None-Match is an asterisk", %{conn: conn, snapshot: snapshot} do
    output = snapshot.rendered_outputs.direct.clash

    conn =
      conn
      |> put_req_header("if-none-match", "*")
      |> get("/api/proxy-rules/direct-list/clash")

    assert response(conn, 304) == ""
    assert get_resp_header(conn, "etag") == [output.etag]
    assert get_resp_header(conn, "x-proxy-rules-generation") == ["12"]
  end

  test "returns the artifact when If-None-Match does not match", %{
    conn: conn,
    snapshot: snapshot
  } do
    output = snapshot.rendered_outputs.proxy.squid

    conn =
      conn
      |> put_req_header("if-none-match", ~s(W/"sha256-not-the-current-output"))
      |> get("/api/proxy-rules/proxy-list/squid")

    assert response(conn, 200) == output.body
    assert get_resp_header(conn, "etag") == [output.etag]
  end

  test "returns a bounded plain 404 for invalid list and format identifiers", %{conn: conn} do
    for path <- [
          "/api/proxy-rules/unknown/raw",
          "/api/proxy-rules/proxy-list/unknown"
        ] do
      response_conn = get(recycle(conn), path)

      assert response(response_conn, 404) == "Not Found"
      assert get_resp_header(response_conn, "content-type") == ["text/plain; charset=utf-8"]
    end
  end

  @tag empty_store: true
  test "returns a bounded plain 503 while no artifact is published", %{conn: conn} do
    conn = get(conn, "/api/proxy-rules/proxy-list/raw")

    assert response(conn, 503) == "Service Unavailable"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "emits artifact-hit telemetry for a successful response", %{conn: conn, snapshot: snapshot} do
    attach_telemetry([:gsmlg, :proxy_rules, :api, :artifact, :hit])
    output = snapshot.rendered_outputs.direct.raw

    conn = get(conn, "/api/proxy-rules/direct-list/raw")

    assert response(conn, 200) == output.body

    assert_receive {:telemetry, %{artifact_size: size, generation: 12},
                    %{list: :direct, format: :raw, status: 200}}

    assert size == output.content_length
  end

  test "emits conditional-hit telemetry for a 304 response", %{
    conn: conn,
    snapshot: snapshot
  } do
    attach_telemetry([:gsmlg, :proxy_rules, :api, :artifact, :conditional_hit])
    output = snapshot.rendered_outputs.proxy.clash

    conn =
      conn
      |> put_req_header("if-none-match", output.etag)
      |> get("/api/proxy-rules/proxy-list/clash")

    assert response(conn, 304) == ""

    assert_receive {:telemetry, %{artifact_size: size, generation: 12},
                    %{list: :proxy, format: :clash, status: 304}}

    assert size == output.content_length
  end

  defp fixture_snapshot do
    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 12,
               compiled_at: @compiled_at,
               sample_limit: 2
             )

    snapshot
  end

  defp replace_current(nil) do
    :sys.replace_state(Store, fn state ->
      :ets.delete(:gsmlg_proxy_rules_store, :current)
      state
    end)
  end

  defp replace_current(snapshot) do
    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)
  end

  defp cache_control do
    assert {:ok, %Configuration{cache_control: cache_control}} = Configuration.load()
    cache_control
  end

  defp http_date(%DateTime{} = date_time) do
    date_time
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :httpd_util.rfc1123_date()
    |> List.to_string()
  end

  defp attach_telemetry(event) do
    owner = self()
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, pid ->
          send(pid, {:telemetry, measurements, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
