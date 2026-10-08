defmodule GSMLG.Web.AgentNotePDF do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Search
  alias GSMLG.Web.AgentNoteContent

  @max_bytes 8_388_608
  @max_package_bytes 33_554_432
  @image_types ~w(image/png image/jpeg image/gif image/webp)

  def export(conn, %{"id" => id} = params) do
    with {revision, ""} when revision > 0 <- Integer.parse(params["expected_revision"] || ""),
         false <- Enum.any?(Map.keys(params), &(&1 not in ~w(id expected_revision))),
         {:ok, pdf} <- admitted_export(id, revision) do
      filename = "note-#{id}.pdf"

      conn
      |> put_resp_content_type("application/pdf")
      |> put_resp_header("x-note-revision", to_string(revision))
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, pdf)
    else
      {:error, :not_found} ->
        error(conn, 404, "not_found", "note not found")

      {:error, {:revision_conflict, details}} ->
        error(
          conn,
          409,
          "stale_revision",
          "the note changed after it was read",
          false,
          details
        )

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "2")
        |> error(429, "export_busy", "PDF export capacity is busy", true)

      {:error, :limit} ->
        error(conn, 413, "export_limit_exceeded", "PDF export limit exceeded")

      {:error, :asset} ->
        error(conn, 422, "export_asset_invalid", "PDF export contains an unsupported image")

      {:error, :timeout} ->
        error(conn, 504, "pdf_export_timeout", "PDF export timed out", true)

      {:error, :renderer} ->
        error(conn, 502, "pdf_renderer_failed", "PDF renderer conversion failed", true)

      {:error, :unavailable} ->
        error(conn, 503, "pdf_renderer_unavailable", "PDF renderer unavailable", true)

      {:error, _} ->
        error(conn, 500, "export_storage_failure", "Failed to read export input", true)

      _ ->
        error(conn, 400, "invalid_input", "expected_revision must be a positive integer")
    end
  end

  defp admitted_export(id, revision) do
    with {:ok, lease} <- GSMLG.Web.AgentNotePDFPool.acquire() do
      try do
        task =
          Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
            with {:ok, snapshot} <- snapshot(id, revision),
                 {:ok, body, boundary} <- package(snapshot),
                 {:ok, pdf} <- convert(body, boundary),
                 do: {:ok, pdf}
          end)

        case Task.yield(task, 35_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> {:error, :timeout}
          {:exit, _} -> {:error, :unavailable}
        end
      after
        GSMLG.Web.AgentNotePDFPool.release(lease)
      end
    end
  end

  defp snapshot(id, revision) do
    GSMLG.Repo.transaction(fn ->
      with {:ok, note} <- Compat.lock_note(id, :active),
           :ok <- Compat.ensure_revision(note, revision) do
        if byte_size(note.content) > 2_097_152,
          do: GSMLG.Repo.rollback(:limit)

        html = AgentNoteContent.render_html(note.content, nil)
        {:ok, tree} = Floki.parse_fragment(html)
        sources = tree |> Floki.find("img") |> Floki.attribute("src") |> Enum.uniq()
        if length(sources) > 64, do: GSMLG.Repo.rollback(:limit)

        assets =
          Enum.map(sources, fn source ->
            path = String.trim_leading(source, "./")

            attachment =
              Enum.find(note.attachments, &(String.trim_leading(&1.path, "./") == path))

            if is_nil(attachment) or attachment.mime not in @image_types or
                 not is_nil(URI.parse(source).scheme) or String.starts_with?(source, "/"),
               do: GSMLG.Repo.rollback(:asset)

            file = attachment.storage_file
            if not is_integer(file.size) or file.size < 0, do: GSMLG.Repo.rollback(:asset)
            if file.size > @max_bytes, do: GSMLG.Repo.rollback(:limit)

            case Compat.get_note_attachment_content(id, attachment.api_id) do
              {:ok, _, bytes} when byte_size(bytes) <= @max_bytes ->
                checksum = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

                if byte_size(bytes) != file.size or not is_binary(file.checksum) or
                     String.downcase(file.checksum) != checksum,
                   do: GSMLG.Repo.rollback(:asset)

                case GSMLG.Web.AgentNoteImageInfo.dimensions(attachment.mime, bytes) do
                  {:ok, _} -> :ok
                  {:error, :pixel_limit} -> GSMLG.Repo.rollback(:limit)
                  _ -> GSMLG.Repo.rollback(:asset)
                end

                {source, "asset-#{length(Enum.take_while(sources, &(&1 != source)))}",
                 attachment.mime, bytes}

              {:ok, _, _} ->
                GSMLG.Repo.rollback(:limit)

              {:error, reason} ->
                GSMLG.Repo.rollback(reason)
            end
          end)

        if Enum.reduce(assets, byte_size(html), fn {_, _, _, bytes}, total ->
             total + byte_size(bytes)
           end) > @max_package_bytes,
           do: GSMLG.Repo.rollback(:limit)

        pixels =
          Enum.reduce(assets, 0, fn {_, _, mime, bytes}, total ->
            {:ok, {width, height}} = GSMLG.Web.AgentNoteImageInfo.dimensions(mime, bytes)
            total + width * height
          end)

        if pixels > 80_000_000, do: GSMLG.Repo.rollback(:limit)

        rewrites = Map.new(assets, fn {source, name, _, _} -> {source, name} end)

        tree =
          Floki.traverse_and_update(tree, fn
            {"img", attrs, children} ->
              {"img",
               Enum.map(attrs, fn
                 {"src", value} -> {"src", Map.fetch!(rewrites, value)}
                 pair -> pair
               end), children}

            element ->
              element
          end)

        %{html: tree |> Floki.raw_html() |> AgentNoteContent.document(), assets: assets}
      else
        {:error, reason} -> GSMLG.Repo.rollback(reason)
      end
    end)
  end

  defp package(%{html: html, assets: assets}) do
    boundary = "gaonote-" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

    parts =
      [
        {"index.html", "text/html; charset=utf-8", html},
        {"footer.html", "text/html; charset=utf-8", "<html><body></body></html>"}
      ] ++ Enum.map(assets, fn {_, name, mime, bytes} -> {name, mime, bytes} end)

    files =
      Enum.map(parts, fn {name, mime, bytes} ->
        [
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"#{name}\"\r\nContent-Type: #{mime}\r\n\r\n",
          bytes,
          "\r\n"
        ]
      end)

    fields =
      Enum.map(~w(preferCssPageSize printBackground failOnResourceLoadingFailed), fn name ->
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\ntrue\r\n"
      end)

    body = IO.iodata_to_binary([files, fields, "--#{boundary}--\r\n"])
    if byte_size(body) <= @max_package_bytes, do: {:ok, body, boundary}, else: {:error, :limit}
  end

  defp convert(body, boundary) do
    url =
      String.trim_trailing(Search.config()[:pdf_renderer_url], "/") <>
        "/forms/chromium/convert/html"

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "multipart/form-data; boundary=#{boundary}"}],
        body
      )

    # Stream and bound the renderer response rather than buffering an arbitrary response.
    case Finch.stream(
           request,
           GSMLG.Finch,
           %{status: nil, headers: [], bytes: 0, chunks: []},
           fn
             {:status, status}, acc ->
               %{acc | status: status}

             {:headers, headers}, acc ->
               %{acc | headers: headers}

             {:data, chunk}, acc ->
               size = acc.bytes + byte_size(chunk)
               if size > 33_554_432, do: throw(:pdf_limit)
               %{acc | bytes: size, chunks: [chunk | acc.chunks]}
           end,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200} = result} ->
        bytes = result.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        type = result.headers |> List.keyfind("content-type", 0, {"", ""}) |> elem(1)

        if String.starts_with?(type, "application/pdf") and String.starts_with?(bytes, "%PDF-"),
          do: {:ok, bytes},
          else: {:error, :renderer}

      {:ok, %{status: status}} when status in [429, 503, 504] ->
        {:error, :unavailable}

      {:ok, _} ->
        {:error, :renderer}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unavailable}
    end
  catch
    :pdf_limit -> {:error, :limit}
  end

  defp error(conn, status, code, message, retryable \\ false, details \\ %{}),
    do:
      conn
      |> put_status(status)
      |> json(%{code: code, message: message, details: details, retryable: retryable})
end
