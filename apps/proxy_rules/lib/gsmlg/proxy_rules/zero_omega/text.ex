defmodule GSMLG.ProxyRules.ZeroOmega.Text do
  @moduledoc false

  @forbidden_line_characters ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/u

  @spec safe_line?(term()) :: boolean()
  def safe_line?(value) when is_binary(value) do
    String.valid?(value) and not Regex.match?(@forbidden_line_characters, value)
  end

  def safe_line?(_value), do: false
end
