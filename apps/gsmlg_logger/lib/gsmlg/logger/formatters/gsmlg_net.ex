defmodule GSMLG.Logger.Formatters.GsmlgNet do
  @moduledoc """
  Custom Erlang's [`:logger` formatter](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#formatters) which
  writes logs in a structured format that can be consumed by `gsmlg.net`.

  This formatter adheres to the `gsmlg.net` project.

  ## Formatter Configuration

  The formatter can be configured with the following options:

  * `:planet` (optional) - set the planet of gsmlg.net.

  For list of shared options see "Shared options" in `GSMLG.Logger`.

  ## Metadata

  For list of other well-known metadata keys see "Metadata" in `GSMLG.Logger`.

  ## Examples

      %{
        time: utc_time(meta),
        level: Atom.to_string(level),
        message: encode(message, redactors),
        metadata: encode(take_metadata(meta, metadata_selector), redactors)
      }
  """
  import GSMLG.Logger.Formatter.{MapBuilder, DateTime, Message, Metadata, RedactorEncoder}
  require Jason.Helpers

  @behaviour GSMLG.Logger.Formatter

  @processed_metadata_keys ~w[file line mfa
                              otel_span_id span_id
                              otel_trace_id trace_id
                              conn]a

  @impl true
  def format(%{level: level, meta: meta, msg: msg}, opts) do
    opts = Keyword.new(opts)
    planet = Keyword.get(opts, :planet, nil)
    encoder_opts = Keyword.get(opts, :encoder_opts, [])
    metadata_keys_or_selector = Keyword.get(opts, :metadata, [])
    metadata_selector = update_metadata_selector(metadata_keys_or_selector, @processed_metadata_keys)
    redactors = Keyword.get(opts, :redactors, [])

    message =
      format_message(msg, meta, %{
        binary: &format_binary_message/1,
        structured: &format_structured_message/1,
        crash: &format_crash_reason(&1, &2, meta)
      })

    line =
      %{
        time: utc_time(meta),
        level: Atom.to_string(level),
        message: encode(message, redactors),
        metadata: encode(take_metadata(meta, metadata_selector), redactors)
      }
      |> maybe_put(:planet, planet)
      |> maybe_put(:request, format_http_request(meta))
      |> maybe_put(:span, format_span(meta))
      |> maybe_put(:trace, format_trace(meta))
      |> Jason.encode_to_iodata!(encoder_opts)

    [line, "\n"]
  end

  @doc false
  def format_binary_message(binary) do
    IO.chardata_to_string(binary)
  end

  @doc false
  def format_structured_message(map) when is_map(map) do
    map
  end

  def format_structured_message(keyword) do
    Enum.into(keyword, %{})
  end

  @doc false
  def format_crash_reason(binary, _reason, _meta) do
    IO.chardata_to_string(binary)
  end

  if Code.ensure_loaded?(Plug.Conn) do
    defp format_http_request(%{conn: %Plug.Conn{} = conn} = assigns) do
      request_method = conn.method |> to_string() |> String.upcase()
      request_url = Plug.Conn.request_url(conn)
      status = conn.status
      user_agent = GSMLG.Logger.Formatter.Plug.get_header(conn, "user-agent")
      remote_ip = GSMLG.Logger.Formatter.Plug.remote_ip(conn)
      referer = GSMLG.Logger.Formatter.Plug.get_header(conn, "referer")
      requested_with = GSMLG.Logger.Formatter.Plug.get_header(conn, "x-requested-with")
      served_by = Plug.Conn.get_req_header(conn, "x-served-by")
      duration = http_request_duration(assigns)
      query_params = case conn.query_string do
        "" -> nil
        query_string when is_binary(query_string) ->
          URI.decode_query(query_string)
        _ -> nil
      end

      Jason.Helpers.json_map(
        protocol: Plug.Conn.get_http_protocol(conn),
        method: request_method,
        request_url: request_url,
        path: conn.request_path,
        query_params: query_params,
        status: status,
        user_agent: user_agent,
        remote_ip: remote_ip,
        referer: referer,
        requested_with: requested_with,
        served_by: served_by,
        duration: duration
      )
    end
  end

  defp format_http_request(_meta), do: nil

  defp http_request_duration(%{duration_us: duration_us}) do
    duration_s = Float.round(duration_us / 1_000, 6)
    "#{duration_s}ms"
  end

  defp http_request_duration(_assigns) do
    nil
  end

  defp format_span(%{otel_span_id: otel_span_id}), do: IO.chardata_to_string(otel_span_id)
  defp format_span(%{span_id: span_id}), do: span_id
  defp format_span(_meta), do: nil

  defp format_trace(%{otel_trace_id: otel_trace_id}), do: IO.chardata_to_string(otel_trace_id)
  defp format_trace(%{trace_id: trace_id}), do: trace_id
  defp format_trace(_meta), do: nil
end
