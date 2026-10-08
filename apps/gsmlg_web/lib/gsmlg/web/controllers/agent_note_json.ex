defmodule GSMLG.Web.AgentNoteJSON do
  @moduledoc false
  defdelegate note(note), to: GSMLG.GaoNote.Compat.Presenter
  defdelegate summary(note), to: GSMLG.GaoNote.Compat.Presenter
  defdelegate mcp_note(note), to: GSMLG.GaoNote.Compat.Presenter
end
