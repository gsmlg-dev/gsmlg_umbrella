defmodule GSMLG.GaoNote.MCPLabelFilterTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Backplane.McpProtocol.Server.{Frame, Response}
  alias GSMLG.GaoNote

  test "tool schemas use the final label contract and exclude creator" do
    create_tool =
      GSMLG.GaoNote.MCP.AdminServer.__components__(:tool)
      |> Enum.find(&(&1.name == "gao_note.create"))

    search_tool =
      GSMLG.GaoNote.MCP.ReadOnlyServer.__components__(:tool)
      |> Enum.find(&(&1.name == "gao_note.search"))

    create_properties = create_tool.input_schema["properties"]
    search_properties = search_tool.input_schema["properties"]

    assert create_properties |> Map.keys() |> Enum.sort() ==
             ["content", "description", "labels", "title"]

    refute Map.has_key?(create_properties, "creator")

    assert search_properties |> Map.keys() |> Enum.sort() ==
             ["label", "limit", "offset", "query"]
  end

  test "search dispatch forwards the label filter and returns only matching notes" do
    matching = note_fixture("MCP matching label", ["topic=ecto"])
    _other_value = note_fixture("MCP other value", ["topic=phoenix"])
    _other_key = note_fixture("MCP other key", ["status=ecto"])

    tool =
      GSMLG.GaoNote.MCP.ReadOnlyServer.__components__(:tool)
      |> Enum.find(&(&1.name == "gao_note.search"))

    assert tool

    assert {:reply, %Response{} = response, _frame} =
             tool.handler.execute(%{"label" => "topic=ecto"}, Frame.new(%{mode: :readonly}))

    assert %{"structuredContent" => %{"notes" => [presented]}} =
             Response.to_protocol(response)

    assert presented["id"] == matching.id
    assert [%{"key" => "topic", "value" => "ecto"}] = presented["labels"]
  end

  defp note_fixture(title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: title, content: "Label filter content", labels: labels},
               %{id: "mcp-label-filter"}
             )

    note
  end
end
