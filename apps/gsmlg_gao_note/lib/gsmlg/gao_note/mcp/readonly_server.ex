defmodule GSMLG.GaoNote.MCP.ReadOnlyServer do
  @moduledoc """
  Read-only GaoNote MCP server backed by Backplane MCP Protocol.
  """

  use Backplane.McpProtocol.Server,
    name: "gsmlg-gao-note-readonly",
    version: "0.1.0",
    capabilities: [:tools, :resources]

  alias Backplane.McpProtocol.Server.Frame
  alias GSMLG.GaoNote.MCP.{Resources, Tools}

  component(Tools.Search, name: "gao_note.search")
  component(Tools.Get, name: "gao_note.get")
  component(Tools.ListTags, name: "gao_note.list_tags")
  component(Tools.ListReferences, name: "gao_note.list_references")
  component(Tools.ListAssets, name: "gao_note.list_assets")

  component(Resources.Note)
  component(Resources.NoteMetadata)
  component(Resources.NoteReferences)
  component(Resources.NoteAssets)
  component(Resources.Tag)
  component(Resources.Asset)

  @impl true
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :mode, :readonly)}
  end
end
