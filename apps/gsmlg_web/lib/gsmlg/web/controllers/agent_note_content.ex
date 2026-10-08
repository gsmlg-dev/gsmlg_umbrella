defmodule GSMLG.Web.AgentNoteContent do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  import Ecto.Query
  alias GSMLG.GaoNote.{CategorySetting, Compat, Note}
  alias GSMLG.GaoNote.Compat.Presenter
  alias GSMLG.Repo

  @csp "default-src 'none'; img-src 'self' data: https:; style-src 'unsafe-inline'; frame-ancestors *; base-uri 'none'; form-action 'none'"

  def raw(conn, %{"id" => id} = params) do
    case Compat.get_note(id) do
      nil ->
        text(conn, 404, "note not found")

      note ->
        case params["type"] do
          nil ->
            conn
            |> put_resp_content_type("text/markdown")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> send_resp(200, note.content)

          "html" ->
            html = render_html(note.content, "/api/notes/#{id}/attachments") |> document()

            conn
            |> put_resp_content_type("text/html")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("content-security-policy", @csp)
            |> send_resp(200, html)

          other ->
            text(conn, 400, "unsupported content type: #{other}")
        end
    end
  end

  def render(conn, %{"content" => content} = params) when is_binary(content) do
    base = params["attachment_base"]

    if is_nil(base) or is_binary(base),
      do:
        conn |> put_resp_content_type("text/html") |> send_resp(200, render_html(content, base)),
      else: text(conn, 400, "invalid attachment_base")
  end

  def render(conn, _), do: text(conn, 400, "content is required")

  def render_html(content, base) do
    html =
      MDEx.to_html!(content,
        render: [unsafe: false],
        extension: [table: true, strikethrough: true, tasklist: true]
      )

    if is_binary(base) do
      escaped =
        base
        |> String.trim_trailing("/")
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      html
      |> String.replace("href=\"./", "href=\"#{escaped}/")
      |> String.replace("src=\"./", "src=\"#{escaped}/")
    else
      html
    end
  end

  def dashboard(conn, _params) do
    notes =
      Note
      |> where([n], is_nil(n.deleted_at))
      |> order_by([n], desc: n.created_at, asc: n.id)
      |> preload(labels: :label_setting)
      |> Repo.all()

    {:ok, settings} = Compat.list_label_keys()
    counts = notes |> Enum.flat_map(& &1.labels) |> Enum.frequencies_by(& &1.label_setting.name)

    labels =
      Enum.map(
        settings,
        &(Presenter.label_setting(&1) |> Map.put(:count, Map.get(counts, &1.name, 0)))
      )

    labels = Enum.sort_by(labels, &{-&1.count, &1.key})
    categories = category_summaries(notes)

    value = %{
      note_count: length(notes),
      embedded_note_count: 0,
      embedding_note: nil,
      label_count: length(settings),
      last_updated_at: if(notes == [], do: nil, else: Presenter.timestamp(hd(notes).updated_at)),
      labels: labels,
      categories: categories,
      recent_updates:
        notes
        |> Enum.take(5)
        |> Enum.map(
          &%{id: &1.id, title: &1.title, updated_at: Presenter.timestamp(&1.updated_at)}
        )
    }

    etag =
      "\"" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(value)), case: :lower) <> "\""

    conn = put_resp_header(conn, "etag", etag)

    if etag in get_req_header(conn, "if-none-match"),
      do: send_resp(conn, 304, ""),
      else: json(conn, value)
  end

  defp category_summaries(notes) do
    configured =
      CategorySetting |> order_by([c], asc: c.position) |> preload(:label_setting) |> Repo.all()

    counts =
      notes
      |> Enum.flat_map(& &1.labels)
      |> Enum.frequencies_by(&{&1.label_setting_id, &1.value || ""})

    configured
    |> Enum.group_by(& &1.label_setting_id)
    |> Map.values()
    |> Enum.sort_by(fn rows -> rows |> Enum.map(& &1.position) |> Enum.min() end)
    |> Enum.map(fn rows ->
      first = hd(rows)
      all = Enum.any?(rows, &is_nil(&1.value))

      values =
        if all do
          counts
          |> Enum.flat_map(fn {{id, value}, count} ->
            if id == first.label_setting_id, do: [%{value: value, count: count}], else: []
          end)
          |> Enum.sort_by(&{-&1.count, &1.value})
        else
          rows
          |> Enum.sort_by(& &1.position)
          |> Enum.map(
            &%{value: &1.value, count: Map.get(counts, {&1.label_setting_id, &1.value}, 0)}
          )
        end

      %{
        key: first.label_setting.name,
        description: first.label_setting.description || "",
        values: values
      }
    end)
  end

  def capabilities(conn, _params),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{markdown: true, pdf: configured_pdf?()})

  def pdf(conn, params) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    if configured_pdf?() do
      GSMLG.Web.AgentNotePDF.export(conn, params)
    else
      conn
      |> put_status(503)
      |> json(%{
        code: "pdf_export_disabled",
        message: "PDF export is not configured",
        details: %{},
        retryable: false
      })
    end
  end

  def document(html) do
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Note content</title><style>body{margin:0;padding:24px;background:#fff;color:#2f2e3f;font:16px/1.6 system-ui,sans-serif}.markdown-body{max-width:960px;margin:auto;overflow-wrap:anywhere}.markdown-body img{max-width:100%;height:auto}.markdown-body table{border-collapse:collapse;display:block;overflow:auto}.markdown-body td,.markdown-body th{border:1px solid #d7dbec;padding:6px 12px}.markdown-body pre{overflow:auto;padding:16px;background:#f5f6fa}.markdown-body blockquote{border-left:4px solid #d7dbec;margin-left:0;padding-left:16px}</style></head><body><main class=\"markdown-body\">#{html}</main></body></html>"
  end

  defp configured_pdf?,
    do:
      is_binary(GSMLG.GaoNote.Compat.Search.config()[:pdf_renderer_url]) and
        GSMLG.GaoNote.Compat.Search.config()[:pdf_renderer_url] != ""

  defp text(conn, status, message),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(status, message)
end
