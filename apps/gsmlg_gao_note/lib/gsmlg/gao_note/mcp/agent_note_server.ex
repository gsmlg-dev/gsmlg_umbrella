defmodule GSMLG.GaoNote.MCP.AgentNoteServer do
  @moduledoc "Canonical Agent Note tools backed by GaoNote."
  use Backplane.McpProtocol.Server,
    name: "agent-note",
    version: "0.1.0",
    capabilities: [:tools]

  alias GSMLG.GaoNote.MCP.AgentNoteTools, as: Tools
  component(Tools.SaveNote, name: "save_note")
  component(Tools.GetNote, name: "get_note")
  component(Tools.ListNotes, name: "list_notes")
  component(Tools.SemanticSearch, name: "semantic_search")
  component(Tools.ReadNoteLines, name: "read_note_lines")
  component(Tools.ReplaceNote, name: "replace_note")
  component(Tools.PatchNote, name: "patch_note")
  component(Tools.DeleteNote, name: "delete_note")
  component(Tools.BulkUpdateNoteLabels, name: "bulk_update_note_labels")
  component(Tools.PutNoteAttachment, name: "put_note_attachment")
  component(Tools.GetNoteAttachmentContent, name: "get_note_attachment_content")
  component(Tools.DeleteNoteAttachment, name: "delete_note_attachment")

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
