defmodule GSMLG.Commander do
  @moduledoc """
  # `GSMLG.Commander` is the worker of the GSMLG.CommandPlatform.
  """

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    start = config |> Keyword.get(:start, false)
    Phoenix.SocketClient.Telemetry.attach_debug_handler()

    children =
      if start do
        [
          {Phoenix.SocketClient, {socket_opts(), name: GSMLG.Commander.Socket}},
          {GSMLG.Commander.GreatHall, []},
          {GSMLG.Commander.Office, []},
          {GSMLG.Commander.Resource, []}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @doc """
  Return socket connection options
  """
  def socket_opts() do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    url = config |> Keyword.get(:platform_url)
    priv_key = config |> Keyword.get(:platform_key)
    name = config |> Keyword.get(:name, "commander-#{Enum.random(100_000..999_999)}")

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
