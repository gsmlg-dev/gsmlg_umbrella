defmodule GSMLG.GaoNote.Sync.Selectors do
  @moduledoc """
  Sync regexes use a conservative common subset of PCRE and Rust regex:
  ASCII literals, escaped regex punctuation, anchors, alternation and simple
  ASCII character classes. Groups, repetition, wildcard dots, Unicode/POSIX
  classes and character-class set operations are rejected before authorization.
  """
  alias GSMLG.GaoNote.Compat.LabelSelector

  def parse(selector) do
    with {:ok, conditions} <- LabelSelector.parse(selector) do
      if Enum.all?(conditions, &portable?/1),
        do: {:ok, conditions},
        else: {:error, :unsupported_sync_regex}
    end
  end

  defp portable?(%{operator: "~=", value: pattern}) do
    syntax?(pattern, false) and
      match?({:ok, _}, :re.compile(pattern, [:unicode, :ucp, :caseless, :dollar_endonly]))
  end

  defp portable?(_condition), do: true

  defp syntax?("", class), do: not class

  defp syntax?(<<"\\", byte, rest::binary>>, false)
       when byte in ~c"\\.^$|?*+(){}[]-",
       do: syntax?(rest, false)

  defp syntax?("[" <> rest, false), do: syntax?(rest, true)
  defp syntax?("]" <> rest, true), do: syntax?(rest, false)
  defp syntax?("--" <> _rest, true), do: false

  defp syntax?(<<byte, rest::binary>>, true)
       when byte in 32..126 and byte not in ~c"[\\&~|",
       do: syntax?(rest, true)

  defp syntax?(<<byte, rest::binary>>, false)
       when byte in 32..126 and byte not in ~c"\\.*+?(){}[]",
       do: syntax?(rest, false)

  defp syntax?(_pattern, _class), do: false
end
