defmodule GSMLG.Web.GaoNoteController do
  use GSMLG.Web, :controller

  alias GSMLG.GaoNote

  action_fallback(GSMLG.Web.FallbackController)

  def index(conn, params) do
    notes =
      params
      |> list_opts()
      |> GaoNote.list_public_notes()

    render(conn, :index, notes: notes)
  end

  def show(conn, %{"id" => id}) do
    with %{} = note <- GaoNote.get_public_note(id) do
      render(conn, :show, note: note)
    else
      nil -> {:error, :not_found}
    end
  end

  def label_settings(conn, params) do
    label_settings = GaoNote.list_label_settings(limit: Map.get(params, "limit"))

    render(conn, :label_settings, label_settings: label_settings)
  end

  def references(conn, %{"id" => id}) do
    with %{} = note <- GaoNote.get_public_note(id) do
      references = GaoNote.list_references(note)

      render(conn, :references, references: references)
    else
      nil -> {:error, :not_found}
    end
  end

  def assets(conn, %{"id" => id}) do
    with %{} = note <- GaoNote.get_public_note(id) do
      assets = GaoNote.list_assets(note)

      render(conn, :assets, note: note, assets: assets)
    else
      nil -> {:error, :not_found}
    end
  end

  defp list_opts(params) do
    [
      search: Map.get(params, "search", Map.get(params, "query")),
      label: Map.get(params, "label"),
      limit: Map.get(params, "limit"),
      offset: Map.get(params, "offset")
    ]
  end
end
