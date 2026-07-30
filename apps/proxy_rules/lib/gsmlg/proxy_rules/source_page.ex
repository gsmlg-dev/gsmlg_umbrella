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
           collect_lines(snapshot.content, offset, start_line, line_limit, byte_limit) do
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

  defp collect_lines(content, offset, line, line_limit, byte_limit) do
    collect_lines(content, offset, line, line_limit, byte_limit, 0, [])
  end

  defp collect_lines(content, offset, line, _line_limit, _byte_limit, _bytes, lines)
       when offset == byte_size(content),
       do: {:ok, Enum.reverse(lines), offset, line}

  defp collect_lines(_content, offset, line, 0, _byte_limit, _bytes, lines),
    do: {:ok, Enum.reverse(lines), offset, line}

  defp collect_lines(content, offset, line, line_limit, byte_limit, bytes, lines) do
    {line_text, next_offset} = next_line(content, offset)
    consumed = next_offset - offset

    cond do
      consumed > byte_limit and lines == [] ->
        {:error, :page_too_large}

      bytes + consumed > byte_limit ->
        {:ok, Enum.reverse(lines), offset, line}

      true ->
        collect_lines(
          content,
          next_offset,
          line + 1,
          line_limit - 1,
          byte_limit,
          bytes + consumed,
          [line_text | lines]
        )
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
end
