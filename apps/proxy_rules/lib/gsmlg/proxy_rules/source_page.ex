defmodule GSMLG.ProxyRules.SourcePage do
  @moduledoc """
  Bounded line pagination over immutable source snapshots.
  """

  alias GSMLG.ProxyRules.SourceSnapshot

  @default_line_limit 200
  @max_line_limit 500
  @default_byte_limit 256 * 1024
  @max_byte_limit 256 * 1024
  @cursor_pattern ~r/\A([0-9a-f]{64}):(\d+):(\d+)\z/
  @sources [:remote_gfwlist, :local_proxy]

  @type error :: :invalid_cursor | :source_changed | :page_too_large | :not_found

  @spec page(atom(), SourceSnapshot.t(), binary() | nil, keyword()) ::
          {:ok, map()} | {:error, error()}
  def page(source, %SourceSnapshot{} = snapshot, cursor, options)
      when source in @sources and is_list(options) do
    line_limit = bounded_limit(options, :line_limit, @default_line_limit, @max_line_limit)
    byte_limit = bounded_limit(options, :byte_limit, @default_byte_limit, @max_byte_limit)

    with {:ok, offset, start_line} <- cursor_position(cursor, snapshot),
         {:ok, lines, next_offset, next_line} <-
           collect_lines(
             source,
             snapshot,
             offset,
             start_line,
             line_limit,
             byte_limit
           ) do
      has_more = next_offset < byte_size(snapshot.content)

      {:ok,
       %{
         source: source,
         version: snapshot.content_sha256,
         availability: snapshot.availability,
         observed_at: snapshot.observed_at,
         last_success_at:
           Map.get(snapshot.metadata, :last_success_at) ||
             Map.get(snapshot.metadata, :fetched_at),
         total_lines: snapshot.line_count,
         start_line: start_line,
         lines: lines,
         next_cursor:
           if(has_more,
             do: encode_cursor(snapshot.content_sha256, next_offset, next_line),
             else: nil
           ),
         has_more: has_more
       }}
    end
  end

  def page(_source, _snapshot, _cursor, _options), do: {:error, :not_found}

  defp bounded_limit(options, key, default, maximum) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _invalid -> default
    end
  end

  defp cursor_position(nil, _snapshot), do: {:ok, 0, 1}

  defp cursor_position(cursor, %SourceSnapshot{} = snapshot)
       when is_binary(cursor) and byte_size(cursor) <= 192 do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [_, version, offset_text, line_text] <- Regex.run(@cursor_pattern, decoded),
         {offset, ""} <- Integer.parse(offset_text),
         {line, ""} <- Integer.parse(line_text),
         :ok <- matching_version(version, snapshot.content_sha256),
         :ok <- valid_position(snapshot.content, offset, line) do
      {:ok, offset, line}
    else
      {:error, :source_changed} = error -> error
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp cursor_position(_cursor, _snapshot), do: {:error, :invalid_cursor}

  defp matching_version(version, version), do: :ok
  defp matching_version(_cursor_version, _snapshot_version), do: {:error, :source_changed}

  defp valid_position(content, offset, line)
       when is_integer(offset) and offset > 0 and offset < byte_size(content) and
              is_integer(line) and line > 1 do
    if :binary.at(content, offset - 1) == ?\n and
         SourceSnapshot.count_lines(binary_part(content, 0, offset)) + 1 == line do
      :ok
    else
      :error
    end
  end

  defp valid_position(_content, _offset, _line), do: :error

  defp collect_lines(source, snapshot, offset, line, line_limit, byte_limit) do
    collect_lines(source, snapshot, offset, line, line_limit, byte_limit, 2, [])
  end

  defp collect_lines(
         source,
         snapshot,
         offset,
         line,
         _line_limit,
         byte_limit,
         encoded_lines_size,
         lines
       )
       when offset == byte_size(snapshot.content) do
    finish_page(
      source,
      snapshot,
      offset,
      line,
      byte_limit,
      encoded_lines_size,
      lines
    )
  end

  defp collect_lines(
         source,
         snapshot,
         offset,
         line,
         0,
         byte_limit,
         encoded_lines_size,
         lines
       ) do
    finish_page(
      source,
      snapshot,
      offset,
      line,
      byte_limit,
      encoded_lines_size,
      lines
    )
  end

  defp collect_lines(
         source,
         snapshot,
         offset,
         line,
         line_limit,
         byte_limit,
         encoded_lines_size,
         lines
       ) do
    {line_text, next_offset} = next_line(snapshot.content, offset)

    candidate_lines_size =
      encoded_lines_size + json_string_size(line_text) + if(lines == [], do: 0, else: 1)

    candidate_size =
      encoded_page_size(
        source,
        snapshot,
        line - length(lines),
        candidate_lines_size,
        next_offset,
        line + 1
      )

    cond do
      candidate_size <= byte_limit ->
        collect_lines(
          source,
          snapshot,
          next_offset,
          line + 1,
          line_limit - 1,
          byte_limit,
          candidate_lines_size,
          [line_text | lines]
        )

      lines == [] ->
        {:error, :page_too_large}

      true ->
        finish_page(
          source,
          snapshot,
          offset,
          line,
          byte_limit,
          encoded_lines_size,
          lines
        )
    end
  end

  defp finish_page(
         source,
         snapshot,
         offset,
         line,
         byte_limit,
         encoded_lines_size,
         lines
       ) do
    start_line = line - length(lines)

    if encoded_page_size(
         source,
         snapshot,
         start_line,
         encoded_lines_size,
         offset,
         line
       ) <= byte_limit do
      {:ok, Enum.reverse(lines), offset, line}
    else
      {:error, :page_too_large}
    end
  end

  defp next_line(content, offset) do
    remaining = byte_size(content) - offset

    case :binary.match(content, "\n", scope: {offset, remaining}) do
      {position, 1} ->
        {binary_part(content, offset, position - offset), position + 1}

      :nomatch ->
        {binary_part(content, offset, remaining), byte_size(content)}
    end
  end

  defp encode_cursor(version, offset, line) do
    Base.url_encode64("#{version}:#{offset}:#{line}", padding: false)
  end

  defp encoded_page_size(
         source,
         snapshot,
         start_line,
         encoded_lines_size,
         next_offset,
         next_line
       ) do
    has_more = next_offset < byte_size(snapshot.content)

    next_cursor_size =
      if has_more do
        snapshot.content_sha256
        |> encode_cursor(next_offset, next_line)
        |> json_string_size()
      else
        byte_size("null")
      end

    last_success_at =
      Map.get(snapshot.metadata, :last_success_at) ||
        Map.get(snapshot.metadata, :fetched_at)

    values = [
      source: json_string_size(Atom.to_string(source)),
      version: json_string_size(snapshot.content_sha256),
      availability: json_string_size(Atom.to_string(snapshot.availability)),
      observed_at: json_value_size(snapshot.observed_at),
      last_success_at: json_value_size(last_success_at),
      total_lines: integer_size(snapshot.line_count),
      start_line: integer_size(start_line),
      lines: encoded_lines_size,
      next_cursor: next_cursor_size,
      has_more: if(has_more, do: byte_size("true"), else: byte_size("false"))
    ]

    2 +
      length(values) - 1 +
      Enum.reduce(values, 0, fn {key, value_size}, total ->
        total + json_string_size(Atom.to_string(key)) + 1 + value_size
      end)
  end

  defp json_value_size(nil), do: byte_size("null")

  defp json_value_size(%DateTime{} = datetime),
    do: datetime |> DateTime.to_iso8601() |> json_string_size()

  defp integer_size(value) when is_integer(value),
    do: value |> Integer.to_string() |> byte_size()

  defp json_string_size(value) when is_binary(value), do: json_string_size(value, 2)

  defp json_string_size(<<>>, size), do: size

  defp json_string_size(<<byte, rest::binary>>, size)
       when byte in [?", ?\\, ?\b, ?\t, ?\n, ?\f, ?\r],
       do: json_string_size(rest, size + 2)

  defp json_string_size(<<byte, rest::binary>>, size) when byte < 0x20,
    do: json_string_size(rest, size + 6)

  defp json_string_size(<<codepoint::utf8, rest::binary>>, size) when codepoint >= 0x80 do
    encoded_size =
      cond do
        codepoint <= 0x7FF -> 2
        codepoint <= 0xFFFF -> 3
        true -> 4
      end

    json_string_size(rest, size + encoded_size)
  end

  defp json_string_size(<<byte, rest::binary>>, size) when byte < 0x80,
    do: json_string_size(rest, size + 1)

  defp json_string_size(<<_invalid_byte, rest::binary>>, size),
    do: json_string_size(rest, size + 6)
end
