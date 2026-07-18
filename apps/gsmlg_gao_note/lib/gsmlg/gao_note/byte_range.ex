defmodule GSMLG.GaoNote.ByteRange do
  @moduledoc """
  Pure parsing and chunk planning for one inclusive HTTP byte range.
  """

  @max_decimal_digits 20

  @type normalized :: {non_neg_integer(), non_neg_integer()}
  @type result :: :full | {:ok, normalized()} | :invalid

  @spec parse([binary()], non_neg_integer()) :: result()
  def parse(headers, size) when is_list(headers) and is_integer(size) and size >= 0 do
    case headers do
      [] -> :full
      [header] -> parse_header(header, size)
      _multiple -> :invalid
    end
  end

  def parse(_headers, _size), do: :invalid

  @spec chunks(integer(), integer(), pos_integer()) :: Enumerable.t()
  def chunks(first, last, chunk_size)
      when is_integer(first) and is_integer(last) and is_integer(chunk_size) and
             first >= 0 and last >= first and chunk_size > 0 do
    Stream.unfold(first, fn
      next when next > last ->
        nil

      next ->
        chunk_last = min(next + chunk_size - 1, last)
        {{next, chunk_last}, chunk_last + 1}
    end)
  end

  def chunks(_first, _last, _chunk_size), do: []

  defp parse_header(header, size) when is_binary(header) do
    case String.split(String.trim(header), "=", parts: 2) do
      [unit, specification] ->
        specification = String.trim(specification)

        if String.downcase(String.trim(unit)) == "bytes" and
             not String.contains?(specification, ",") do
          parse_specification(specification, size)
        else
          :invalid
        end

      _invalid ->
        :invalid
    end
  end

  defp parse_header(_header, _size), do: :invalid

  defp parse_specification(specification, size) do
    case String.split(specification, "-", parts: 2) do
      [first_text, ""] when first_text != "" ->
        with {:ok, first} <- decimal(first_text),
             true <- size > 0 and first < size do
          {:ok, {first, size - 1}}
        else
          _invalid -> :invalid
        end

      ["", suffix_text] when suffix_text != "" ->
        with {:ok, suffix} <- decimal(suffix_text),
             true <- size > 0 and suffix > 0 do
          {:ok, {max(size - suffix, 0), size - 1}}
        else
          _invalid -> :invalid
        end

      [first_text, last_text] when first_text != "" and last_text != "" ->
        with {:ok, first} <- decimal(first_text),
             {:ok, last} <- decimal(last_text),
             true <- size > 0 and first <= last and first < size do
          {:ok, {first, min(last, size - 1)}}
        else
          _invalid -> :invalid
        end

      _invalid ->
        :invalid
    end
  end

  defp decimal(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_decimal_digits do
    if decimal_digits?(value) do
      case Integer.parse(value) do
        {integer, ""} -> {:ok, integer}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp decimal(_value), do: :error

  defp decimal_digits?(<<>>), do: true

  defp decimal_digits?(<<digit, rest::binary>>) when digit in ?0..?9,
    do: decimal_digits?(rest)

  defp decimal_digits?(_value), do: false
end
