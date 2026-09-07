defmodule GSMLG.AdminWeb.BrowserAPI.ByteRange do
  @moduledoc false

  def parse([], _size), do: :full

  def parse(["bytes=" <> value], size) when is_integer(size) and size > 0 do
    case String.split(value, "-", parts: 2) do
      [first, last] when first != "" -> explicit(first, last, size)
      ["", suffix] -> suffix(suffix, size)
      _invalid -> :invalid
    end
  end

  def parse(_headers, _size), do: :invalid

  def chunks(first, last, chunk_size)
      when is_integer(first) and is_integer(last) and first <= last and chunk_size > 0 do
    Stream.unfold(first, fn
      next when next > last -> nil
      next -> {{next, min(next + chunk_size - 1, last)}, next + chunk_size}
    end)
  end

  defp explicit(first, "", size) do
    with {:ok, first} <- integer(first), true <- first < size do
      {:ok, {first, size - 1}}
    else
      _invalid -> :invalid
    end
  end

  defp explicit(first, last, size) do
    with {:ok, first} <- integer(first),
         {:ok, last} <- integer(last),
         true <- first <= last and first < size do
      {:ok, {first, min(last, size - 1)}}
    else
      _invalid -> :invalid
    end
  end

  defp suffix(value, size) do
    with {:ok, length} <- integer(value), true <- length > 0 do
      {:ok, {max(size - length, 0), size - 1}}
    else
      _invalid -> :invalid
    end
  end

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _invalid -> :error
    end
  end
end
