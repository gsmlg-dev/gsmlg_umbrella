defmodule GSMLG.GaoNote.Compat.ContentPatch do
  @moduledoc "Strict, uniquely anchored content hunks preserving original line endings."
  @syntax_error "expected @@ hunks with context, - deletion, and + insertion lines; file directives are not supported"
  @context_error "context must match exactly one location in the original content"

  def apply(content, patch) when is_binary(content) and is_binary(patch) do
    original = raw_lines(content)
    normalized = Enum.map(original, &normalize_line/1)

    with {:ok, hunks} <- parse(patch),
         {:ok, locations} <- locate(normalized, hunks),
         {:ok, output, cursor, removed_eof} <- render(original, content, hunks, locations) do
      result = IO.iodata_to_binary([output, Enum.drop(original, cursor)])
      {:ok, if(removed_eof, do: remove_final_ending(result), else: result)}
    end
  end

  defp parse(patch) do
    lines = patch |> raw_lines() |> Enum.map(&normalize_patch_line/1)

    if List.first(lines) == "@@" and Enum.all?(lines, &valid_patch_line?/1) do
      hunks =
        lines
        |> Enum.drop(1)
        |> Enum.reduce([[]], fn
          "@@", hunks -> [[] | hunks]
          <<prefix, text::binary>>, [hunk | hunks] -> [[{prefix, text} | hunk] | hunks]
        end)
        |> Enum.reverse()
        |> Enum.map(&Enum.reverse/1)

      cond do
        Enum.any?(hunks, &(&1 == [])) ->
          {:error, empty_hunk_error(lines)}

        Enum.any?(hunks, &(old_lines(&1) == [])) ->
          {:error, "each hunk needs existing context or deletion lines"}

        true ->
          {:ok, hunks}
      end
    else
      {:error, @syntax_error}
    end
  end

  defp empty_hunk_error(lines) do
    {index, next} =
      lines
      |> Enum.with_index()
      |> Enum.find_value(fn
        {"@@", index} ->
          next = Enum.at(lines, index + 1)
          if next in [nil, "@@"], do: {index, next}

        _line ->
          nil
      end)

    message =
      if next == nil do
        "Update hunk does not contain any lines"
      else
        "Unexpected line found in update hunk: '@@'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
      end

    "invalid hunk at line #{index + 4}, #{message}"
  end

  defp valid_patch_line?("@@"), do: true
  defp valid_patch_line?(<<prefix, _::binary>>) when prefix in [?\s, ?+, ?-], do: true
  defp valid_patch_line?(_line), do: false

  # Length-prefixed lines prevent substring matches crossing line boundaries.
  # The built-in binary matcher avoids rescanning long repeated line prefixes in Elixir.
  defp locate(original, hunks) do
    {encoded, boundaries, _size} =
      original
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{0 => 0}, 0}, fn {line, n}, {encoded, boundaries, size} ->
        size = size + 8 + byte_size(line)
        {[encoded, encode_line(line)], Map.put(boundaries, size, n), size}
      end)

    encoded = IO.iodata_to_binary(encoded)

    Enum.reduce_while(hunks, {:ok, []}, fn hunk, {:ok, locations} ->
      pattern = hunk |> old_lines() |> Enum.map(&encode_line/1) |> IO.iodata_to_binary()

      case unique_location(encoded, pattern, boundaries, 0, nil) do
        {:ok, start} -> {:cont, {:ok, [start | locations]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, locations} -> {:ok, Enum.reverse(locations)}
      error -> error
    end
  end

  defp unique_location(encoded, pattern, boundaries, offset, found)
       when offset < byte_size(encoded) do
    case :binary.match(encoded, pattern, scope: {offset, byte_size(encoded) - offset}) do
      {start, size} ->
        if Map.has_key?(boundaries, start) and Map.has_key?(boundaries, start + size) do
          if found == nil do
            unique_location(
              encoded,
              pattern,
              boundaries,
              start + 1,
              Map.fetch!(boundaries, start)
            )
          else
            {:error, @context_error}
          end
        else
          unique_location(encoded, pattern, boundaries, start + 1, found)
        end

      :nomatch ->
        location_result(found)
    end
  end

  defp unique_location(_encoded, _pattern, _boundaries, _offset, found),
    do: location_result(found)

  defp location_result(nil), do: {:error, @context_error}
  defp location_result(found), do: {:ok, found}
  defp encode_line(line), do: <<byte_size(line)::unsigned-big-64, line::binary>>
  defp old_lines(hunk), do: for({prefix, text} <- hunk, prefix != ?+, do: text)
  defp new_lines(hunk), do: for({prefix, text} <- hunk, prefix != ?-, do: text)

  defp render(original, content, hunks, locations) do
    original = List.to_tuple(original)

    Enum.zip(hunks, locations)
    |> Enum.reduce_while({:ok, [], 0, false}, fn {hunk, start}, {:ok, output, cursor, _removed} ->
      if start < cursor do
        {:halt, {:error, "hunks must be ordered and must not overlap"}}
      else
        ending = start + length(old_lines(hunk))
        untouched = slice(original, cursor, start)

        if old_lines(hunk) == new_lines(hunk) do
          {:cont, {:ok, [output, untouched, slice(original, start, ending)], ending, false}}
        else
          newline = if String.ends_with?(elem(original, start), "\r\n"), do: "\r\n", else: "\n"
          terminated = ending != tuple_size(original) or String.ends_with?(content, "\n")
          changed = render_hunk(hunk, original, start, newline, terminated)

          removed =
            ending == tuple_size(original) and not String.ends_with?(content, "\n") and
              elem(List.last(hunk), 0) == ?-

          {:cont, {:ok, [output, untouched, changed], ending, removed}}
        end
      end
    end)
  end

  defp render_hunk(hunk, original, start, newline, terminated) do
    {marked, _} =
      Enum.reduce(Enum.reverse(hunk), {[], false}, fn {prefix, _} = line,
                                                      {marked, output_after} ->
        {[{line, output_after} | marked], output_after or prefix != ?-}
      end)

    {output, _} =
      Enum.reduce(marked, {[], start}, fn
        {{?-, _text}, _after}, {output, index} ->
          {output, index + 1}

        {{?+, text}, after?}, {output, index} ->
          ending = if terminated or after?, do: newline, else: ""
          {[output, text, ending], index}

        {{?\s, _text}, after?}, {output, index} ->
          raw = elem(original, index)
          ending = if after? and not String.ends_with?(raw, "\n"), do: newline, else: ""
          {[output, raw, ending], index + 1}
      end)

    output
  end

  defp slice(_original, start, ending) when start == ending, do: []

  defp slice(original, start, ending),
    do: for(index <- start..(ending - 1), do: elem(original, index))

  defp raw_lines(""), do: []

  defp raw_lines(content) do
    case :binary.split(content, "\n", [:global]) |> Enum.reverse() do
      ["" | rest] -> rest |> Enum.reverse() |> Enum.map(&(&1 <> "\n"))
      [last | rest] -> Enum.map(Enum.reverse(rest), &(&1 <> "\n")) ++ [last]
    end
  end

  defp normalize_line(line) do
    if String.ends_with?(line, "\n") do
      line |> String.trim_trailing("\n") |> strip_cr()
    else
      line
    end
  end

  defp normalize_patch_line(line) do
    line
    |> String.trim_trailing("\n")
    |> strip_cr()
  end

  defp strip_cr(line),
    do:
      if(String.ends_with?(line, "\r"), do: binary_part(line, 0, byte_size(line) - 1), else: line)

  defp remove_final_ending(result) do
    cond do
      String.ends_with?(result, "\r\n") -> binary_part(result, 0, byte_size(result) - 2)
      String.ends_with?(result, ["\r", "\n"]) -> binary_part(result, 0, byte_size(result) - 1)
      true -> result
    end
  end
end
