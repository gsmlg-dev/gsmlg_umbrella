defmodule GSMLG.ProxyRules.Renderer do
  @moduledoc """
  Renders normalized rules into the supported immutable text formats.
  """

  alias GSMLG.ProxyRules.Rule

  @type format :: :raw | :squid | :clash

  @spec render([Rule.t()], format()) :: binary()
  def render(rules, format) when is_list(rules) and format in [:raw, :squid, :clash] do
    rules
    |> Enum.sort_by(& &1.domain.name)
    |> Enum.map(&line(&1.domain.name, format))
    |> render_lines(format)
    |> IO.iodata_to_binary()
  end

  defp line(domain, :raw), do: domain
  defp line(domain, :squid), do: [?. | domain]
  defp line(domain, :clash), do: ["- '+.", domain, ?']

  defp render_lines([], :clash), do: "payload: []\n"
  defp render_lines(lines, :clash), do: ["payload:\n", append_trailing_newline(lines)]
  defp render_lines(lines, _format), do: append_trailing_newline(lines)

  defp append_trailing_newline([]), do: []
  defp append_trailing_newline(lines), do: [Enum.intersperse(lines, ?\n), ?\n]
end
