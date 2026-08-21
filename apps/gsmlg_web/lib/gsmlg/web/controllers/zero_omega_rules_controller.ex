defmodule GSMLG.Web.ZeroOmegaRulesController do
  use GSMLG.Web, :controller

  alias GSMLG.ProxyRules
  alias GSMLG.ProxyRules.ZeroOmega.RenderedRuleList

  def switchy(conn, _params), do: serve(conn, :switchy)
  def pac(conn, _params), do: serve(conn, :pac)

  defp serve(conn, format) do
    with {:ok, options} <- parse_options(conn.query_string, format),
         {:ok, result} <- ProxyRules.export_zeroomega(format, options) do
      send_export(conn, result)
    else
      {:error, :not_ready} ->
        send_plain(conn, 503, "Service Unavailable", "no-store")

      {:error, :not_found} ->
        send_plain(conn, 404, "Not Found", "no-store")

      {:error, _diagnostics_or_options} ->
        send_plain(conn, 400, "Invalid ZeroOmega options", "no-store")
    end
  end

  defp parse_options(query_string, format) do
    with {:ok, pairs} <- decode_query_pairs(query_string),
         :ok <- validate_query_keys(pairs, format) do
      options_from_pairs(pairs, format)
    end
  end

  defp decode_query_pairs(query_string) do
    {:ok, query_string |> URI.query_decoder() |> Enum.to_list()}
  rescue
    _error -> {:error, :invalid_query}
  end

  defp validate_query_keys(pairs, :switchy) do
    validate_unique_allowed_keys(pairs, ["mode", "match_profile", "default_profile"])
  end

  defp validate_query_keys(pairs, :pac) do
    with :ok <- validate_unique_allowed_keys(pairs, ["proxy"]),
         true <- Enum.count(pairs, fn {key, _value} -> key == "proxy" end) == 1 do
      :ok
    else
      _invalid -> {:error, :invalid_query}
    end
  end

  defp validate_unique_allowed_keys(pairs, allowed) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.all?(keys, &(&1 in allowed)) and length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp options_from_pairs(pairs, :switchy) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      {"mode", "binary"}, {:ok, options} ->
        {:cont, {:ok, [{:mode, :binary} | options]}}

      {"mode", "result"}, {:ok, options} ->
        {:cont, {:ok, [{:mode, :result} | options]}}

      {"mode", _invalid}, _acc ->
        {:halt, {:error, :invalid_query}}

      {"match_profile", value}, {:ok, options} ->
        {:cont, {:ok, [{:match_profile, value} | options]}}

      {"default_profile", value}, {:ok, options} ->
        {:cont, {:ok, [{:default_profile, value} | options]}}
    end)
    |> reverse_options()
  end

  defp options_from_pairs([{"proxy", proxy}], :pac), do: {:ok, [proxy: proxy]}
  defp options_from_pairs(_pairs, :pac), do: {:error, :invalid_query}

  defp reverse_options({:ok, options}), do: {:ok, Enum.reverse(options)}
  defp reverse_options(error), do: error

  defp send_export(
         conn,
         %{
           generation: generation,
           compiled_at: compiled_at,
           output: %RenderedRuleList{} = output
         }
       ) do
    conn =
      conn
      |> put_resp_header("etag", output.etag)
      |> put_resp_header("last-modified", http_date(compiled_at))
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-proxy-rules-generation", Integer.to_string(generation))
      |> put_resp_header("content-type", output.content_type)
      |> put_resp_header("content-length", Integer.to_string(output.content_length))

    if etag_matches?(get_req_header(conn, "if-none-match"), output.etag) do
      send_resp(conn, 304, "")
    else
      send_resp(conn, 200, output.body)
    end
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

  defp http_date(%DateTime{} = date_time) do
    date_time
    |> DateTime.to_unix(:second)
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp send_plain(conn, status, body, cache_control) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", cache_control)
    |> send_resp(status, body)
  end
end
