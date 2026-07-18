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
  component(Tools.ListLabelSettings, name: "gao_note.list_label_settings")

  component(Resources.Note)
  component(Resources.NoteMetadata)
  component(Resources.LabelSetting)

  @impl true
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :mode, :readonly)}
  end
end
