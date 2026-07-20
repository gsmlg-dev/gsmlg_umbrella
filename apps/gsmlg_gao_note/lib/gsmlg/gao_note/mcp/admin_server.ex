defmodule GSMLG.GaoNote.MCP.AdminServer do
  @moduledoc """
  Authenticated administrative GaoNote MCP server backed by Backplane MCP Protocol.
  """

  use Backplane.McpProtocol.Server,
    name: "gsmlg-gao-note-admin",
    version: "0.1.0",
    capabilities: [:tools, :resources]

  alias Backplane.McpProtocol.Server.Frame
  alias GSMLG.GaoNote.MCP.{Resources, Tools}

  component(Tools.Search, name: "gao_note.search")
  component(Tools.Get, name: "gao_note.get")
  component(Tools.GetAttachmentWithContent, name: "gao_note.get_attachment_with_content")
  component(Tools.ListLabelSettings, name: "gao_note.list_label_settings")
  component(Tools.CreateNote, name: "gao_note.create_note")
  component(Tools.CreateLabelSetting, name: "gao_note.create_label_setting")
  component(Tools.UpdateNote, name: "gao_note.update_note")
  component(Tools.Delete, name: "gao_note.delete")
  component(Tools.SetLabels, name: "gao_note.set_labels")
  component(Tools.PutAttachment, name: "gao_note.put_attachment")
  component(Tools.DeleteAttachment, name: "gao_note.delete_attachment")

  component(Resources.Note)
  component(Resources.NoteMetadata)
  component(Resources.LabelSetting)

  @impl true
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :mode, :admin)}
  end
end
