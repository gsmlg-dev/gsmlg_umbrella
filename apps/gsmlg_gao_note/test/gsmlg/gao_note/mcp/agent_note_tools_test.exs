defmodule GSMLG.GaoNote.MCP.AgentNoteToolsTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.{Frame, Response}
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.MCP.AgentNoteTools, as: Tools

  defp frame, do: Frame.new(%{actor: %{id: "mcp-test-actor", source: "mcp_api_key"}})
  defp call(name, args), do: Tools.execute(name, args, frame())

  defp save do
    assert {:reply, %Response{isError: false, structured_content: %{id: id, revision: 1}}, _} =
             call("save_note", %{
               "title" => "Test",
               "content" => "a\r\nb\n",
               "labels" => [["env", "prod"]]
             })

    id
  end

  test "save get and list emit canonical MCP DTOs with revision and typed labels" do
    id = save()

    assert {:reply,
            %Response{
              structured_content: %{
                id: ^id,
                content: "a\r\nb\n",
                attachments: [],
                labels: [%{key: "env", value: "prod", description: "", value_type: "text"}],
                revision: 1
              }
            }, _} = call("get_note", %{"id" => id})

    assert {:reply, %Response{structured_content: %{notes: [summary]}}, _} =
             call("list_notes", %{"label" => "env=prod"})

    assert summary.id == id
    refute Map.has_key?(summary, :content)
    refute Map.has_key?(summary, :attachments)

    assert {:reply, %Response{structured_content: %{notes: []}}, _} =
             call("list_notes", %{"limit" => 0})
  end

  test "read lines preserves CR and trailing empty line" do
    id = save()

    assert {:reply,
            %Response{
              structured_content: %{
                id: ^id,
                revision: 1,
                tag: tag,
                lines: [%{n: 1, text: "a\r"}, %{n: 2, text: "b"}, %{n: 3, text: ""}]
              }
            }, _} = call("read_note_lines", %{"id" => id})

    assert byte_size(tag) == 8
  end

  test "strict patch increments changed revision and no-op replacement keeps it" do
    id = save()

    assert {:reply, %Response{structured_content: %{id: ^id, revision: 2, changed: true}}, _} =
             call("patch_note", %{
               "id" => id,
               "expected_revision" => 1,
               "content" => %{"apply_patch" => "@@\n a\n-b\n+B"}
             })

    assert Compat.get_note(id).content == "a\r\nB\r\n"

    args = %{
      "id" => id,
      "expected_revision" => 2,
      "title" => "Test",
      "content" => "a\r\nB\r\n",
      "labels" => [["env", "prod"]],
      "attachments" => []
    }

    assert {:reply, %Response{structured_content: %{id: ^id, revision: 2, changed: false}}, _} =
             call("replace_note", args)
  end

  test "mutation failures are structured and preserve the complete note" do
    id = save()

    assert {:reply,
            %Response{
              isError: true,
              structured_content: %{
                code: "revision_conflict",
                retryable: false,
                details: %{note_id: ^id, expected_revision: 2, current_revision: 1}
              }
            },
            _} = call("patch_note", %{"id" => id, "expected_revision" => 2, "title" => "changed"})

    assert {:reply, %Response{isError: true, structured_content: %{code: "patch_failed"}}, _} =
             call("patch_note", %{
               "id" => id,
               "expected_revision" => 1,
               "title" => "changed",
               "content" => %{"apply_patch" => "@@\n-missing\n+new"}
             })

    assert {:reply, %Response{isError: true, structured_content: %{code: "invalid_request"}}, _} =
             call("patch_note", %{"id" => id, "expected_revision" => 1})

    assert %{title: "Test", content: "a\r\nb\n", revision: 1} = Compat.get_note(id)

    assert {:error, %Error{code: -32602}, _} =
             call("patch_note", %{"id" => id, "expected_revision" => 1, "content" => nil})
  end

  test "non-mutation tool errors remain protocol errors" do
    id = Ecto.UUID.generate()
    assert {:error, %Error{code: -32002}, _} = call("get_note", %{"id" => id})

    assert {:reply,
            %Response{
              isError: true,
              structured_content: %{code: "not_found", details: %{note_id: ^id}}
            },
            _} = call("patch_note", %{"id" => id, "expected_revision" => 1, "title" => "changed"})

    assert {:error, %Error{code: -32602}, _} = call("list_notes", %{"label" => "~bad"})
    id = save()

    assert {:error, %Error{code: -32600, data: %{code: "revision_conflict"}}, _} =
             call("delete_note", %{"id" => id, "expected_revision" => 2})

    assert {:reply, %Response{structured_content: %{deleted: true}}, _} =
             call("delete_note", %{"id" => id, "expected_revision" => 1})

    assert Compat.get_note(id) == nil
  end

  test "bulk count schema and revisions reflect semantic label changes" do
    id = save()
    args = %{"selector" => "env=prod", "set" => [["team", "core"]]}

    assert {:reply, %Response{structured_content: %{matched: 1, updated: 1, unchanged: 0}}, _} =
             call("bulk_update_note_labels", args)

    assert Compat.get_note(id).revision == 2

    assert {:reply, %Response{structured_content: %{matched: 1, updated: 0, unchanged: 1}}, _} =
             call("bulk_update_note_labels", args)
  end

  test "search returns canonical result wrapper and reports unavailable external capability" do
    assert {:reply, %Response{structured_content: %{results: []}}, _} =
             call("semantic_search", %{"query" => "Q", "limit" => 0})

    assert {:error, %Error{code: -32603}, _} =
             call("semantic_search", %{"query" => "Q", "limit" => 1})
  end

  test "mutations require an authenticated actor even when called directly" do
    assert {:error, %Error{code: -32602}, _} =
             Tools.execute("save_note", %{"title" => "T", "content" => "C"}, Frame.new())
  end

  test "registered component validators enforce both directions through Backplane callbacks" do
    tool =
      Enum.find(GSMLG.GaoNote.MCP.AgentNoteServer.__components__(), &(&1.name == "save_note"))

    assert {:ok, %{"labels" => []}} = tool.validate_input.(%{"title" => "T", "content" => "C"})

    assert {:error, _} =
             tool.validate_input.(%{"title" => "T", "content" => "C", "attachments" => []})

    assert {:ok, _} = tool.validate_output.(%{id: "n", revision: 1})
    assert {:error, _} = tool.validate_output.(%{id: "n"})
  end

  test "invalid title and typed labels return validation errors without changing the note" do
    id = save()

    assert {:reply,
            %Response{
              isError: true,
              structured_content: %{code: "validation_error", message: "title must not be empty"}
            },
            _} =
             call("patch_note", %{"id" => id, "expected_revision" => 1, "title" => ""})

    assert {:ok, _} = Compat.define_label_key("priority", %{value_type: "number"})

    assert {:reply, %Response{isError: true, structured_content: %{code: "validation_error"}}, _} =
             call("patch_note", %{
               "id" => id,
               "expected_revision" => 1,
               "labels" => [["priority", "NaN"]]
             })

    assert %{title: "Test", revision: 1} = Compat.get_note(id)
  end

  test "attachment tools preserve note scoped identity and text or binary representations" do
    with_storage(fn ->
      first = save()
      second = save()

      input = %{
        "note_id" => first,
        "expected_revision" => 1,
        "attachment_id" => "shared",
        "path" => "doc.txt",
        "mime" => "text/plain",
        "content" => "hello",
        "content_base64" => "aGVsbG8="
      }

      assert {:reply,
              %Response{
                structured_content: %{created: true, revision: 2, attachment: %{id: "shared"}}
              }, _} = call("put_note_attachment", input)

      assert {:reply,
              %Response{structured_content: %{content: "hello", attachment: %{id: "shared"}}},
              _} =
               call("get_note_attachment_content", %{
                 "note_id" => first,
                 "attachment_id" => "shared"
               })

      assert {:error, %Error{code: -32002}, _} =
               call("get_note_attachment_content", %{
                 "note_id" => second,
                 "attachment_id" => "shared"
               })

      assert {:error,
              %Error{
                code: -32602,
                message: "attachment path cannot change for existing id: shared"
              },
              _} =
               call(
                 "put_note_attachment",
                 input |> Map.put("expected_revision", 2) |> Map.put("path", "other.txt")
               )

      assert {:reply, %Response{structured_content: %{created: true, revision: 2}}, _} =
               call("put_note_attachment", Map.put(input, "note_id", second))

      assert {:reply, %Response{structured_content: %{deleted: false, revision: nil}}, _} =
               call("delete_note_attachment", %{
                 "note_id" => first,
                 "attachment_id" => "absent",
                 "expected_revision" => 2
               })

      assert {:reply, %Response{structured_content: %{deleted: true, revision: 3}}, _} =
               call("delete_note_attachment", %{
                 "note_id" => first,
                 "attachment_id" => "shared",
                 "expected_revision" => 2
               })

      assert {:reply, %Response{structured_content: %{content: "hello"}}, _} =
               call("get_note_attachment_content", %{
                 "note_id" => second,
                 "attachment_id" => "shared"
               })

      binary = %{
        "note_id" => second,
        "expected_revision" => 2,
        "attachment_id" => "binary",
        "path" => "blob.bin",
        "mime" => "application/octet-stream",
        "content_base64" => "AP8="
      }

      assert {:reply, %Response{structured_content: %{created: true, revision: 3}}, _} =
               call("put_note_attachment", binary)

      Application.put_env(:gsmlg_storage, :agent_note_mcp_bytes, <<0, 255>>)

      assert {:reply, %Response{structured_content: data}, _} =
               call("get_note_attachment_content", %{
                 "note_id" => second,
                 "attachment_id" => "binary"
               })

      assert data.content_base64 == "AP8="
      refute Map.has_key?(data, :content)
    end)
  end

  defmodule StorageStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, _bytes, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "")
    end

    get("/*path",
      do:
        send_resp(conn, 200, Application.get_env(:gsmlg_storage, :agent_note_mcp_bytes, "hello"))
    )

    delete("/*path", do: send_resp(conn, 204, ""))
  end

  defp with_storage(fun) do
    {:ok, stub} = Bandit.start_link(plug: StorageStub, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(stub)

    values = %{
      allowed_types: %{"gao_note_attachment" => :any},
      s3_access_key_id: "test",
      s3_bucket: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_secret_access_key: "test",
      agent_note_mcp_bytes: "hello"
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    try do
      Oban.Testing.with_testing_mode(:manual, fun)
    after
      GenServer.stop(stub)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end
  end
end
