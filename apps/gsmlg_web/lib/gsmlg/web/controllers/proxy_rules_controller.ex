defmodule GSMLG.Web.ProxyRulesController do
  use GSMLG.Web, :controller

  alias GSMLG.ProxyRules
  alias GSMLG.ProxyRules.{Output, Telemetry}

  def show(conn, %{"list" => list_identifier, "format" => format_identifier}) do
    with {:ok, list} <- list_name(list_identifier),
         {:ok, format} <- format_name(format_identifier),
         {:ok, %{generation: generation, output: output}} <-
           ProxyRules.get_artifact_response(list, format) do
      send_artifact(conn, list, format, generation, output)
    else
      {:error, :not_found} -> send_plain(conn, 404, "Not Found")
      {:error, :not_ready} -> send_plain(conn, 503, "Service Unavailable")
    end
  end

  defp list_name("proxy-list"), do: {:ok, :proxy}
  defp list_name("direct-list"), do: {:ok, :direct}
  defp list_name(_identifier), do: {:error, :not_found}

  defp format_name("raw"), do: {:ok, :raw}
  defp format_name("squid"), do: {:ok, :squid}
  defp format_name("clash"), do: {:ok, :clash}
  defp format_name(_identifier), do: {:error, :not_found}

  defp send_artifact(conn, list, format, generation, %Output{} = output) do
    conn = put_validator_headers(conn, generation, output)

    if etag_matches?(get_req_header(conn, "if-none-match"), output.etag) do
      emit_api_event(:conditional_hit, 304, list, format, generation, output)
      send_resp(conn, 304, "")
    else
      emit_api_event(:hit, 200, list, format, generation, output)

      conn
      |> put_resp_header("content-length", to_string(output.content_length))
      |> put_resp_header("content-type", output.content_type)
      |> send_resp(200, output.body)
    end
  end

  defp put_validator_headers(conn, generation, %Output{} = output) do
    conn
    |> put_resp_header("etag", output.etag)
    |> put_resp_header("last-modified", http_date(output.last_modified))
    |> put_resp_header("cache-control", cache_control())
    |> put_resp_header("x-proxy-rules-generation", Integer.to_string(generation))
  end

  defp etag_matches?(header_values, current_etag) do
    Enum.any?(header_values, fn header_value ->
      header_value
      |> String.split(",")
      |> Enum.any?(fn candidate ->
        candidate = String.trim(candidate)
        candidate == "*" or comparable_etag(candidate) == current_etag
      end)
    end)
  end

  defp comparable_etag("W/\"" <> remainder), do: "\"" <> remainder
  defp comparable_etag("\"" <> _remainder = etag), do: etag
  defp comparable_etag(_candidate), do: nil

  defp cache_control do
    :proxy_rules
    |> Application.fetch_env!(:settings)
    |> Map.fetch!(:cache_control)
  end

  defp http_date(%DateTime{} = date_time) do
    date_time
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :httpd_util.rfc1123_date()
    |> List.to_string()
  end

  defp emit_api_event(kind, status, list, format, generation, output) do
    _ =
      Telemetry.emit(
        [:api, :artifact, kind],
        %{artifact_size: output.content_length, generation: generation},
        %{list: list, format: format, status: status}
      )

    :ok
  end

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
