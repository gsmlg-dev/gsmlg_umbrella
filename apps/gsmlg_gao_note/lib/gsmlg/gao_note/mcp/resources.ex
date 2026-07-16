defmodule GSMLG.GaoNote.MCP.Resources do
  @moduledoc false

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Response
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Presenter

  def read(uri, frame) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "gaonote", host: "notes", path: "/" <> note_path} ->
        read_note(uri, note_path, frame)

      %URI{scheme: "gaonote", host: "label_settings", path: "/" <> label_setting_id} ->
        read_label_setting(uri, label_setting_id, frame)

      %URI{scheme: "gaonote", host: "attachments", path: "/" <> attachment_id} ->
        read_attachment(uri, attachment_id, frame)

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

      {note, ["attachments"]} ->
        attachments = GaoNote.list_attachments(note.id)

        {:reply,
         Response.resource()
         |> Response.json(%{"attachments" => Enum.map(attachments, &Presenter.attachment/1)}),
         frame}

      {_note, _unknown} ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}
    end
  end

  defp read_label_setting(uri, label_setting_id, frame) do
    case GaoNote.get_label_setting(label_setting_id) do
      nil -> {:error, Error.resource(:not_found, %{uri: uri}), frame}
      label_setting -> {:reply, Response.resource() |> Response.json(%{"label_setting" => Presenter.label_setting(label_setting)}), frame}
    end
  end

  defp read_attachment(uri, attachment_id, frame) do
    with attachment when not is_nil(attachment) <- GaoNote.get_attachment(attachment_id),
         note when not is_nil(note) <- resource_note(attachment.note_id, mode(frame)) do
      {:reply,
       Response.resource()
       |> Response.json(%{"attachment" => Presenter.attachment(attachment)}), frame}
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

  use Backplane.McpProtocol.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}",
    name: "gao_note.note",
    mime_type: "text/markdown"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.NoteMetadata do
  @moduledoc "Read GaoNote metadata."

  use Backplane.McpProtocol.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}/metadata",
    name: "gao_note.note.metadata",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.NoteAttachments do
  @moduledoc "Read GaoNote attachment metadata."

  use Backplane.McpProtocol.Server.Component,
    type: :resource,
    uri_template: "gaonote://notes/{id}/attachments",
    name: "gao_note.note.attachments",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.LabelSetting do
  @moduledoc "Read a GaoNote label_setting."

  use Backplane.McpProtocol.Server.Component,
    type: :resource,
    uri_template: "gaonote://label_settings/{id}",
    name: "gao_note.label_setting",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end

defmodule GSMLG.GaoNote.MCP.Resources.Attachment do
  @moduledoc "Read GaoNote attachment metadata."

  use Backplane.McpProtocol.Server.Component,
    type: :resource,
    uri_template: "gaonote://attachments/{attachment_id}",
    name: "gao_note.attachment",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, frame), do: GSMLG.GaoNote.MCP.Resources.read(uri, frame)
end
