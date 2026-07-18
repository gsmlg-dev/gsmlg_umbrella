defmodule GSMLG.Web.GaoNoteJSON do
  alias GSMLG.GaoNote.Presenter

  def index(%{notes: notes}) do
    %{data: Enum.map(notes, &Presenter.note_summary/1)}
  end

  def show(%{note: note}) do
    %{data: Presenter.note(note)}
  end

  def label_settings(%{label_settings: label_settings}) do
    %{data: Enum.map(label_settings, &Presenter.label_setting/1)}
  end
end
