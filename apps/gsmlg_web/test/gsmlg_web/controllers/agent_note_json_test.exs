defmodule GSMLG.Web.AgentNoteJSONTest do
  use ExUnit.Case, async: true
  alias GSMLG.Web.AgentNoteJSON

  test "REST and MCP preserve their separate label DTOs and Unix seconds" do
    note = %{
      id: "n",
      title: "Title",
      content: "Body",
      revision: 3,
      created_at: ~U[2026-10-08 00:00:00Z],
      updated_at: ~U[2026-10-08 00:00:00Z],
      labels: [
        %{
          value: "ecto",
          label_setting: %{name: "Topic", description: "Group", value_type: "date-time"}
        }
      ],
      attachments: [
        %{
          id: "internal",
          api_id: "external",
          path: "./file.txt",
          mime: "text/plain",
          description: "File"
        }
      ]
    }

    assert %{
             labels: [["Topic", "ecto"]],
             created_at: 1_791_417_600,
             revision: 3,
             attachments: [%{id: "external", path: "file.txt"}]
           } = AgentNoteJSON.note(note)

    assert %{labels: [%{key: "Topic", value_type: "datetime", description: "Group"}]} =
             AgentNoteJSON.mcp_note(note)

    summary = AgentNoteJSON.summary(note)
    refute Map.has_key?(summary, :content)
    refute Map.has_key?(summary, :attachments)
  end
end
