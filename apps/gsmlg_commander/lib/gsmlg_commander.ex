defmodule GSMLGCommander do
  @moduledoc """
  Documentation for `GSMLGCommander`.
  """

  @doc """
  Return socket connection options
  """
  def socket_opts() do
    config = Application.get_env(:gsmlg_commander, GSMLGCommander)

    url = config |> Keyword.get(:platform_url)
    priv_key = config |> Keyword.get(:secret_key_base)
    name = config |> Keyword.get(:name)

    sign_at = :os.system_time(:seconds)

    [
      url: url,
      params: %{
        signature: :crypto.mac(:hmac, :sha256, priv_key, "#{name}/#{sign_at}") |> Base.encode16(),
        name: name,
        sign_at: sign_at
      }
    ]
  end
end
