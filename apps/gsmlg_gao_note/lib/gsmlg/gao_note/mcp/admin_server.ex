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
  component(Tools.ListLabelSettings, name: "gao_note.list_label_settings")
  component(Tools.ListAttachments, name: "gao_note.list_attachments")
  component(Tools.Create, name: "gao_note.create")
  component(Tools.CreateLabelSetting, name: "gao_note.create_label_setting")
  component(Tools.Update, name: "gao_note.update")
  component(Tools.Delete, name: "gao_note.delete")
  component(Tools.SetLabels, name: "gao_note.set_labels")
  component(Tools.AttachExistingAttachment, name: "gao_note.attachments.attach_existing")
  component(Tools.UploadBase64Attachment, name: "gao_note.attachments.upload_base64")
  component(Tools.UpdateAttachment, name: "gao_note.attachments.update")
  component(Tools.DetachAttachment, name: "gao_note.attachments.detach")

  component(Resources.Note)
  component(Resources.NoteMetadata)
  component(Resources.NoteAttachments)
  component(Resources.LabelSetting)
  component(Resources.Attachment)

  @impl true
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :mode, :admin)}
  end
end
