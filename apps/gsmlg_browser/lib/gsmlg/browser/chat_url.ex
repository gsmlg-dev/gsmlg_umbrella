defmodule GSMLG.Browser.ChatURL do
  @moduledoc false

  @default_hosts ["gemini.google.com"]
  @max_bytes 2_048

  def from_rpc(result, current \\ nil)

  def from_rpc(result, current) when is_map(result) do
    case Map.fetch(result, "chat_url") do
      :error -> {:ok, current}
      {:ok, value} -> validate(value)
    end
  end

  def from_rpc(_result, _current), do: {:error, :invalid_chat_url}

  def validate(nil), do: {:ok, nil}

  def validate(value) when is_binary(value) and byte_size(value) in 1..@max_bytes do
    with true <- String.valid?(value) and not Regex.match?(~r/[\x00-\x20\x7f]/, value),
         %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           port: port,
           fragment: nil
         } <- URI.parse(value),
         true <- is_binary(host) and String.downcase(host) in allowed_hosts(),
         true <- port in [nil, 443] do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_chat_url}
    end
  end

  def validate(_value), do: {:error, :invalid_chat_url}

  defp allowed_hosts do
    configured = Application.get_env(:gsmlg_browser, :gemini_hosts, @default_hosts)

    case configured do
      hosts when is_list(hosts) ->
        hosts
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&String.downcase/1)
        |> Enum.uniq()
        |> then(fn hosts -> Enum.uniq(@default_hosts ++ hosts) end)

      _invalid ->
        @default_hosts
    end
  end
end
