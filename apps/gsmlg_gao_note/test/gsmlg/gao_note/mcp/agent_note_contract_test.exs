defmodule GSMLG.GaoNote.MCP.AgentNoteContractTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.MCP.AgentNoteTools, as: Tools

  @names ~w(save_note get_note list_notes semantic_search read_note_lines replace_note patch_note delete_note bulk_update_note_labels put_note_attachment get_note_attachment_content delete_note_attachment)

  test "canonical inventory has exactly twelve tools and no resources" do
    assert Enum.sort(Tools.tool_names()) == Enum.sort(@names)
    components = GSMLG.GaoNote.MCP.AgentNoteServer.__components__()
    assert Enum.all?(components, &match?(%Backplane.McpProtocol.Server.Component.Tool{}, &1))
    assert Enum.sort(Enum.map(components, & &1.name)) == Enum.sort(@names)
  end

  test "save accepts only title content and tuple labels" do
    schema = Tools.input_schema("save_note")
    assert schema["additionalProperties"] == false
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(content labels title)
    assert Enum.sort(schema["required"]) == ~w(content title)

    assert {:ok, %{"labels" => []}} =
             Tools.validate("save_note", %{"title" => "", "content" => ""})

    assert {:ok, %{"labels" => [["key", "value"]]}} =
             Tools.validate("save_note", %{
               "title" => "T",
               "content" => "C",
               "labels" => [["key", "value"]]
             })

    for params <- [
          %{"title" => "T", "content" => "C", "attachments" => []},
          %{"title" => "T", "content" => "C", "labels" => nil},
          %{"title" => "T", "content" => "C", "labels" => ["key=value"]}
        ] do
      assert {:error, _} = Tools.validate("save_note", params)
    end
  end

  test "replace is closed and requires all writable fields" do
    params = %{
      "id" => "n",
      "expected_revision" => 1,
      "title" => "",
      "content" => "",
      "attachments" => [],
      "labels" => []
    }

    assert {:ok, ^params} = Tools.validate("replace_note", params)

    for key <- Map.keys(params),
        do: assert({:error, _} = Tools.validate("replace_note", Map.delete(params, key)))

    assert {:error, _} = Tools.validate("replace_note", Map.put(params, "extra", true))

    assert {:ok, %{"expected_revision" => 0}} =
             Tools.validate("replace_note", Map.put(params, "expected_revision", 0))
  end

  test "patch distinguishes omission from explicit null and validates strict content objects" do
    base = %{"id" => "n", "expected_revision" => 1}
    assert {:ok, ^base} = Tools.validate("patch_note", base)

    assert {:ok, %{"content" => %{"apply_patch" => "@@\n-old\n+new"}}} =
             Tools.validate(
               "patch_note",
               Map.put(base, "content", %{"apply_patch" => "@@\n-old\n+new"})
             )

    for key <- ~w(title content attachments labels) do
      assert {:error, _} = Tools.validate("patch_note", Map.put(base, key, nil))
    end

    assert {:error, _} =
             Tools.validate(
               "patch_note",
               Map.put(base, "content", %{"apply_patch" => "@@", "extra" => "x"})
             )
  end

  test "aggregate attachment inputs require XOR while standalone put accepts equal dual content" do
    attachment = %{"id" => "a", "path" => "./a.txt", "mime" => "text/plain", "content" => "abc"}
    base = %{"id" => "n", "expected_revision" => 1, "attachments" => [attachment]}
    assert {:ok, _} = Tools.validate("patch_note", base)

    assert {:error, _} =
             Tools.validate(
               "patch_note",
               Map.put(base, "attachments", [Map.put(attachment, "content_base64", "YWJj")])
             )

    assert {:error, _} =
             Tools.validate(
               "patch_note",
               Map.put(base, "attachments", [Map.put(attachment, "content", nil)])
             )

    put =
      attachment
      |> Map.delete("id")
      |> Map.merge(%{
        "note_id" => "n",
        "attachment_id" => "a",
        "expected_revision" => 1,
        "content_base64" => "YWJj"
      })

    assert {:ok, %{"description" => ""}} = Tools.validate("put_note_attachment", put)

    assert {:error, _} =
             Tools.validate("put_note_attachment", Map.put(put, "content_base64", "eA=="))

    assert {:error, _} =
             Tools.validate("put_note_attachment", Map.put(put, "update_content", true))

    assert {:error, _} =
             Tools.validate(
               "put_note_attachment",
               Map.delete(put, "content") |> Map.put("content_base64", "YWJj=")
             )
  end

  test "list and semantic search retain reference nullable defaults and unknown-field behavior" do
    assert {:ok, %{"limit" => nil, "offset" => nil, "label" => nil}} =
             Tools.validate("list_notes", %{"limit" => nil, "extra" => "ignored"})

    for limit <- [-1, 4_294_967_296, 1.0],
        do: assert({:error, _} = Tools.validate("list_notes", %{"limit" => limit}))

    assert {:ok, %{"query" => "Q", "limit" => 0, "label" => nil}} =
             Tools.validate("semantic_search", %{"query" => "Q", "limit" => 0})

    assert {:error, _} = Tools.validate("semantic_search", %{"query" => "Q"})
    assert {:ok, %{"id" => "n"}} = Tools.validate("get_note", %{"id" => "n", "extra" => true})
  end

  test "bulk default lists remain non-null and all advertised tools have closed output schemas" do
    assert {:ok, %{"selector" => "env", "set" => [], "remove" => []}} =
             Tools.validate("bulk_update_note_labels", %{"selector" => "env"})

    assert {:error, _} =
             Tools.validate("bulk_update_note_labels", %{"selector" => "env", "set" => nil})

    for name <- @names, do: assert(Tools.output_schema(name)["additionalProperties"] == false)
  end

  test "advertised revision minimum is enforced by the mutation as a structured request error" do
    assert Tools.input_schema("patch_note")["properties"]["expected_revision"]["minimum"] == 1
    frame = Backplane.McpProtocol.Server.Frame.new(%{actor: %{id: "mcp-test"}})

    assert {:reply,
            %Backplane.McpProtocol.Server.Response{
              isError: true,
              structured_content: %{code: "invalid_request"}
            },
            _} =
             Tools.execute(
               "patch_note",
               %{"id" => "n", "expected_revision" => 0, "title" => "T"},
               frame
             )
  end
end
