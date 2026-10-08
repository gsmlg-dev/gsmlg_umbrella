defmodule GSMLG.GaoNote.Compat.NoteLines do
  @moduledoc "Line inspection preserving raw content, with Agent Note FNV-1a tags."
  import Bitwise

  def from_note(%{id: id, revision: revision, content: content}) do
    lines =
      content
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.map(fn {text, n} -> %{n: n, text: text} end)

    %{id: id, revision: revision, tag: tag(content), lines: lines}
  end

  defp tag(content) do
    content
    |> :binary.bin_to_list()
    |> Enum.reduce(0x811C9DC5, fn byte, hash ->
      band(bxor(hash, byte) * 0x01000193, 0xFFFFFFFF)
    end)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
