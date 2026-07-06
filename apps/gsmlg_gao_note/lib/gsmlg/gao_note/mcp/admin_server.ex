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
  component(Tools.ListTags, name: "gao_note.list_tags")
  component(Tools.ListReferences, name: "gao_note.list_references")
  component(Tools.ListAssets, name: "gao_note.list_assets")
  component(Tools.Create, name: "gao_note.create")
  component(Tools.CreateTag, name: "gao_note.create_tag")
  component(Tools.Update, name: "gao_note.update")
  component(Tools.Delete, name: "gao_note.delete")
  component(Tools.SetTags, name: "gao_note.set_tags")
  component(Tools.AddReference, name: "gao_note.references.add")
  component(Tools.UpdateReference, name: "gao_note.references.update")
  component(Tools.RemoveReference, name: "gao_note.references.remove")
  component(Tools.AttachExistingAsset, name: "gao_note.assets.attach_existing")
  component(Tools.UploadBase64Asset, name: "gao_note.assets.upload_base64")
  component(Tools.UpdateAsset, name: "gao_note.assets.update")
  component(Tools.DetachAsset, name: "gao_note.assets.detach")

  component(Resources.Note)
  component(Resources.NoteMetadata)
  component(Resources.NoteReferences)
  component(Resources.NoteAssets)
  component(Resources.Tag)
  component(Resources.Asset)

  @impl true
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :mode, :admin)}
  end
end
