defmodule GSMLG.GaoNote.Compat.DomainTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote.Compat

  defp save(labels, attachments \\ []) do
    {:ok, note} =
      Compat.save_note(
        %{title: "Title", content: "Body", labels: labels, attachments: attachments},
        nil
      )

    note
  end

  test "exact label keys preserve case and selectors filter before pagination" do
    a = save([{"Topic", "First"}])
    b = save([{"topic", "second"}])
    assert {:ok, [found]} = Compat.list_notes(%{label: "Topic=First", limit: 1})
    assert found.id == a.id
    assert {:ok, 1} = Compat.count_notes(%{label: "topic=second"})
    assert {:ok, []} = Compat.list_notes(%{limit: 0})
    assert {:ok, keys} = Compat.list_label_keys()
    assert Enum.any?(keys, &(&1.name == "Topic"))
    assert Enum.any?(keys, &(&1.name == "topic"))
    assert b.revision == 1
  end

  test "bulk label mutations increment only changed notes and batches preflight every revision" do
    a = save([{"env", "prod"}])
    b = save([{"env", "prod"}])

    assert {:ok, %{matched: 2, updated: 2, unchanged: 0}} =
             Compat.bulk_update_note_labels(
               %{selector: "env=prod", set: [{"team", "core"}], remove: []},
               nil
             )

    assert {:ok, %{matched: 2, updated: 0, unchanged: 2}} =
             Compat.bulk_update_note_labels(
               %{selector: "env=prod", set: [{"team", "core"}], remove: []},
               nil
             )

    assert {:error, {:revision_conflict, _}} =
             Compat.batch_delete_notes(
               %{notes: [%{id: a.id, expected_revision: 2}, %{id: b.id, expected_revision: 1}]},
               nil
             )

    assert active = Compat.get_note(a.id)
    assert active.revision == 2

    assert {:ok, %{requested: 2, deleted: 2}} =
             Compat.batch_delete_notes(
               %{notes: [%{id: a.id, expected_revision: 2}, %{id: b.id, expected_revision: 2}]},
               nil
             )
  end

  test "attachment public ids are note scoped and targeted upserts preserve other attachments" do
    with_storage(fn ->
      input = %{
        id: "shared",
        path: "./doc.txt",
        mime: "text/plain",
        description: "",
        content: "hello"
      }

      a = save([], [input])
      b = save([], [input])
      assert a.attachments |> hd() |> Map.get(:api_id) == "shared"
      assert b.attachments |> hd() |> Map.get(:api_id) == "shared"
      assert hd(a.attachments).id != hd(b.attachments).id

      assert {:ok, %{attachment: attachment, revision: 2, created: false}} =
               Compat.put_note_attachment(a.id, "shared", 1, input, nil)

      assert attachment.api_id == "shared"

      assert {:ok, %{revision: 2, changed: false}} =
               Compat.delete_note_attachment(a.id, "absent", 2, nil)

      assert {:ok, %{revision: 3, changed: true}} =
               Compat.delete_note_attachment(a.id, "shared", 2, nil)

      assert {:ok, _attachment, "hello"} = Compat.get_note_attachment_content(b.id, "shared")
    end)
  end

  defmodule StorageStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, _, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "")
    end

    get("/*path", do: send_resp(conn, 200, "hello"))
    delete("/*path", do: send_resp(conn, 204, ""))
  end

  defp with_storage(fun) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    {:ok, stub} = Bandit.start_link(plug: StorageStub, port: port, startup_log: false)

    values = %{
      allowed_types: %{"gao_note_attachment" => :any},
      s3_access_key_id: "test",
      s3_bucket: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_secret_access_key: "test"
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    try do
      Oban.Testing.with_testing_mode(:manual, fun)
    after
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      GenServer.stop(stub)
    end
  end
end
