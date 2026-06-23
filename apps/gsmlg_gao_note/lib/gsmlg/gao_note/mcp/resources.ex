defmodule GSMLG.GaoNote.MCP.Resources do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Response
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Presenter

  def read(uri, frame) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "gaonote", host: "notes", path: "/" <> note_path} ->
        read_note(uri, note_path, frame)

      %URI{scheme: "gaonote", host: "tags", path: "/" <> tag_id} ->
        read_tag(uri, tag_id, frame)

      %URI{scheme: "gaonote", host: "assets", path: "/" <> asset_id} ->
        read_asset(uri, asset_id, frame)

      _ ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}
    end
  end

  def read(_uri, frame), do: {:error, Error.resource(:not_found, %{}), frame}

  defp read_note(uri, note_path, frame) do
    [id | rest] = String.split(note_path, "/", parts: 2)
    note = resource_note(id, mode(frame))

    case {note, rest} do
      {nil, _rest} ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}

      {note, []} ->
        {:reply, Response.resource() |> Response.text(note.content || ""), frame}

      {note, ["metadata"]} ->
        {:reply, Response.resource() |> Response.json(%{"note" => Presenter.note(note)}), frame}

      {note, ["references"]} ->
        references = GaoNote.list_references(note)

        {:reply,
         Response.resource()
         |> Response.json(%{"references" => Enum.map(references, &Presenter.reference/1)}), frame}

      {note, ["assets"]} ->
        assets = GaoNote.list_assets(note)

        {:reply,
         Response.resource()
         |> Response.json(%{"assets" => Enum.map(assets, &Presenter.asset_json(&1, note))}),
         frame}

      {_note, _unknown} ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}
    end
  end

  defp read_tag(uri, tag_id, frame) do
    case GaoNote.get_tag(tag_id) do
      nil -> {:error, Error.resource(:not_found, %{uri: uri}), frame}
      tag -> {:reply, Response.resource() |> Response.json(%{"tag" => Presenter.tag(tag)}), frame}
    end
  end

  defp read_asset(uri, asset_id, frame) do
    with asset when not is_nil(asset) <- GaoNote.get_asset(asset_id),
         note when not is_nil(note) <- resource_note(asset.note_id, mode(frame)) do
      {:reply,
       Response.resource()
       |> Response.json(%{"asset" => Presenter.asset_json(asset, note)}), frame}
    else
      _ -> {:error, Error.resource(:not_found, %{uri: uri}), frame}
    end
  end

  defp resource_note(note_id, :admin), do: GaoNote.get_note(note_id)
  defp resource_note(note_id, _readonly), do: GaoNote.get_public_note(note_id)

  defp mode(%{assigns: %{mode: :admin}}), do: :admin
  defp mode(%{assigns: %{"mode" => "admin"}}), do: :admin
  defp mode(_frame), do: :readonly
end

defmodule GSMLG.GaoNote.MCP.Resources.Note do
  @moduledoc "Read GaoNote content."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}",
    name: "gao_note.note",
    mime_type: "text/markdown"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.NoteMetadata do
  @moduledoc "Read GaoNote metadata."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}/metadata",
    name: "gao_note.note.metadata",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.NoteReferences do
  @moduledoc "Read GaoNote web references."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}/references",
    name: "gao_note.note.references",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.NoteAssets do
  @moduledoc "Read GaoNote asset metadata."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}/assets",
    name: "gao_note.note.assets",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.Tag do
  @moduledoc "Read a GaoNote tag."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://tags/{id}",
    name: "gao_note.tag",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.Asset do
  @moduledoc "Read GaoNote asset metadata."

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "gaonote://assets/{asset_id}",
    name: "gao_note.asset",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end
