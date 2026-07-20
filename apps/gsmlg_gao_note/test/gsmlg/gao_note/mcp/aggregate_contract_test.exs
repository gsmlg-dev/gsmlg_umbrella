defmodule GSMLG.GaoNote.MCP.AggregateContractTest do
  use ExUnit.Case, async: true

  @removed_tool_names ~w(
    gao_note.create
    gao_note.update
    gao_note.list_attachments
    gao_note.attachments.attach_existing
    gao_note.attachments.upload_base64
    gao_note.attachments.update
    gao_note.attachments.detach
    gao_note.list_references
    gao_note.references.add
    gao_note.references.update
    gao_note.references.remove
    gao_note.list_assets
    gao_note.assets.upload_base64
    gao_note.assets.update
    gao_note.assets.remove
  )

  @removed_resource_names ~w(
    gao_note.note.attachments
    gao_note.attachment
    gao_note.note.references
    gao_note.reference
    gao_note.note.assets
    gao_note.asset
  )

  test "readonly and admin servers advertise only aggregate contracts" do
    readonly_tools = component_names(GSMLG.GaoNote.MCP.ReadOnlyServer, :tool)
    admin_tools = component_names(GSMLG.GaoNote.MCP.AdminServer, :tool)

    assert readonly_tools == ~w(
             gao_note.get
             gao_note.get_attachment_with_content
             gao_note.list_label_settings
             gao_note.search
           )

    assert admin_tools == ~w(
             gao_note.create_label_setting
             gao_note.create_note
             gao_note.delete
             gao_note.delete_attachment
             gao_note.get
             gao_note.get_attachment_with_content
             gao_note.list_label_settings
             gao_note.put_attachment
             gao_note.search
             gao_note.set_labels
             gao_note.update_note
           )

    assert Enum.filter(@removed_tool_names, &(&1 in readonly_tools or &1 in admin_tools)) == []

    refute Enum.any?(readonly_tools ++ admin_tools, fn name ->
             String.contains?(name, ["reference", "asset"])
           end)

    readonly_resources = components(GSMLG.GaoNote.MCP.ReadOnlyServer, :resource)
    admin_resources = components(GSMLG.GaoNote.MCP.AdminServer, :resource)

    assert component_names(readonly_resources) ==
             ~w(gao_note.label_setting gao_note.note gao_note.note.metadata)

    assert component_names(admin_resources) ==
             component_names(readonly_resources)

    resource_names = component_names(readonly_resources ++ admin_resources)

    assert Enum.filter(@removed_resource_names, &(&1 in resource_names)) == []

    refute Enum.any?(readonly_resources ++ admin_resources, fn resource ->
             resource
             |> Map.get(:uri_template, "")
             |> String.contains?(["attachment", "reference", "asset"])
           end)
  end

  test "create_note schema defaults an optional aggregate attachment list" do
    schema = tool("gao_note.create_note").input_schema

    assert Map.keys(schema["properties"]) |> Enum.sort() ==
             ~w(attachments content labels title)

    assert Enum.sort(schema["required"]) == ~w(content title)
    assert schema["additionalProperties"] == false

    attachments = schema["properties"]["attachments"]
    assert attachments["type"] == "array"
    assert attachments["default"] == []
    assert attachments["description"] =~ "Defaults to an empty list"

    assert_attachment_item_schema(attachments["items"])

    assert {:error, _message, []} =
             GSMLG.GaoNote.MCP.Tools.validate_attachment_input(%{
               "id" => "attachment-1",
               "path" => "data.txt",
               "mime" => "text/plain"
             })
  end

  test "update_note schema mutates note fields without accepting attachments" do
    schema = tool("gao_note.update_note").input_schema

    assert Map.keys(schema["properties"]) |> Enum.sort() ==
             ~w(content id labels title)

    assert schema["required"] == ~w(id)
    assert schema["additionalProperties"] == false
    refute Map.has_key?(schema["properties"], "attachments")
    refute GSMLG.GaoNote.MCP.Tools.description("gao_note.update_note") =~ "attachment"

    assert {:error, _errors} =
             Peri.validate(
               GSMLG.GaoNote.MCP.Tools.UpdateNote.__mcp_raw_schema__(),
               %{"id" => "note-1", "attachments" => []}
             )
  end

  test "standalone attachment schemas expose exact strict fields" do
    get_schema = tool("gao_note.get_attachment_with_content").input_schema

    assert Map.keys(get_schema["properties"]) |> Enum.sort() ==
             ~w(attachment_id note_id)

    assert Enum.sort(get_schema["required"]) == ~w(attachment_id note_id)
    assert get_schema["additionalProperties"] == false

    put_schema = tool("gao_note.put_attachment").input_schema

    assert Map.keys(put_schema["properties"]) |> Enum.sort() ==
             ~w(attachment_id content content_base64 description mime note_id path update_content)

    assert Enum.sort(put_schema["required"]) ==
             ~w(attachment_id description mime note_id path update_content)

    assert put_schema["additionalProperties"] == false
    assert put_schema["properties"]["update_content"]["type"] == "boolean"

    base64 = put_schema["properties"]["content_base64"]
    assert base64["contentEncoding"] == "base64"

    assert base64["pattern"] ==
             "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"

    assert put_schema["oneOf"] == [
             %{
               "properties" => %{"update_content" => %{"const" => false}},
               "not" => %{
                 "anyOf" => [
                   %{"required" => ["content"]},
                   %{"required" => ["content_base64"]}
                 ]
               }
             },
             %{
               "properties" => %{"update_content" => %{"const" => true}},
               "oneOf" => [
                 %{
                   "required" => ["content"],
                   "not" => %{"required" => ["content_base64"]}
                 },
                 %{
                   "required" => ["content_base64"],
                   "not" => %{"required" => ["content"]}
                 }
               ]
             }
           ]

    delete_schema = tool("gao_note.delete_attachment").input_schema

    assert Map.keys(delete_schema["properties"]) |> Enum.sort() ==
             ~w(attachment_id note_id)

    assert Enum.sort(delete_schema["required"]) == ~w(attachment_id note_id)
    assert delete_schema["additionalProperties"] == false
  end

  test "put_attachment runtime schema enforces the content update matrix" do
    schema = GSMLG.GaoNote.MCP.Tools.PutAttachment.__mcp_raw_schema__()

    base = %{
      "note_id" => "note-1",
      "attachment_id" => "attachment-1",
      "path" => "data.txt",
      "mime" => "text/plain",
      "description" => "Data"
    }

    assert {:ok, _args} = Peri.validate(schema, Map.put(base, "update_content", false))

    assert {:error, _errors} =
             Peri.validate(
               schema,
               Map.merge(base, %{"update_content" => false, "content" => "raw"})
             )

    assert {:error, _errors} =
             Peri.validate(
               schema,
               Map.merge(base, %{"update_content" => false, "content_base64" => "cmF3"})
             )

    assert {:error, _errors} = Peri.validate(schema, Map.put(base, "update_content", true))

    assert {:ok, _args} =
             Peri.validate(
               schema,
               Map.merge(base, %{"update_content" => true, "content" => "raw"})
             )

    assert {:ok, _args} =
             Peri.validate(
               schema,
               Map.merge(base, %{"update_content" => true, "content_base64" => "cmF3"})
             )

    assert {:error, _errors} =
             Peri.validate(
               schema,
               Map.merge(base, %{
                 "update_content" => true,
                 "content" => "raw",
                 "content_base64" => "cmF3"
               })
             )

    assert {:error, _errors} =
             Peri.validate(
               schema,
               Map.merge(base, %{"update_content" => true, "content_base64" => "cmF3="})
             )

    assert {:error, _errors} =
             Peri.validate(schema, Map.put(base, "unexpected", "field"))
  end

  test "standalone attachment tools expose exact access annotations" do
    assert GSMLG.GaoNote.MCP.Tools.GetAttachmentWithContent.annotations() == %{
             "readOnlyHint" => true,
             "destructiveHint" => false,
             "idempotentHint" => true,
             "openWorldHint" => false
           }

    assert GSMLG.GaoNote.MCP.Tools.PutAttachment.annotations() == %{
             "readOnlyHint" => false,
             "destructiveHint" => true,
             "idempotentHint" => true,
             "openWorldHint" => false
           }

    assert GSMLG.GaoNote.MCP.Tools.DeleteAttachment.annotations() == %{
             "readOnlyHint" => false,
             "destructiveHint" => true,
             "idempotentHint" => true,
             "openWorldHint" => false
           }

    assert GSMLG.GaoNote.MCP.Tools.Delete.annotations() == %{
             "readOnlyHint" => false,
             "destructiveHint" => true,
             "idempotentHint" => false,
             "openWorldHint" => false
           }
  end

  defp assert_attachment_item_schema(item) do
    assert item["type"] == "object"
    assert item["additionalProperties"] == false

    assert Map.keys(item["properties"]) |> Enum.sort() ==
             ~w(content content_base64 description id mime path)

    assert Enum.sort(item["required"]) == ~w(id mime path)
    assert item["properties"]["description"]["default"] == ""
    assert item["properties"]["id"]["description"] =~ "Globally unique"
    assert item["properties"]["path"]["description"] =~ "./data.txt"
    assert item["properties"]["path"]["description"] =~ "data.txt"
    assert item["properties"]["mime"]["description"] =~ "server verifies"

    base64 = item["properties"]["content_base64"]
    assert base64["contentEncoding"] == "base64"
    assert is_binary(base64["pattern"])
    assert length(item["oneOf"]) == 2

    for rejected_field <-
          ~w(storage_file_id storage_file upload role caption alt_text position metadata) do
      refute Map.has_key?(item["properties"], rejected_field)
    end
  end

  defp tool(name) do
    GSMLG.GaoNote.MCP.AdminServer.__components__(:tool)
    |> Enum.find(&(&1.name == name))
  end

  defp components(server, type), do: server.__components__(type)

  defp component_names(server, type) when is_atom(server) do
    server
    |> components(type)
    |> component_names()
  end

  defp component_names(components) do
    components
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
