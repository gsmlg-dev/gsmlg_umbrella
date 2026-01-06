defmodule GSMLG.Commander do
  @moduledoc """
  # `GSMLG.Commander` is the worker of the GSMLG.CommandPlatform.

  This module provides two modes of operation:
  1. Agent mode (start: true) - Runs on remote machines to be managed
  2. Server mode (server: true) - Runs on the management server

  ## Configuration

      config :gsmlg_commander, GSMLG.Commander,
        start: false,  # Enable agent mode
        server: true,  # Enable server mode (TokenManager)
        platform_url: "wss://...",
        platform_key: "..."
  """

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    start = config |> Keyword.get(:start, false)
    server = config |> Keyword.get(:server, true)
    Phoenix.SocketClient.Telemetry.attach_debug_handler()

    # Server-side services (always start when not in agent mode)
    server_children =
      if server do
        [
          # Token Manager for agent authentication
          {GSMLG.Commander.TokenManager, []}
        ]
      else
        []
      end

    # Agent-side services (only start when configured as agent)
    agent_children =
      if start do
        [
          # Registry for PTY session lookup
          {Registry, keys: :unique, name: GSMLG.Commander.SessionRegistry},
          # Session manager for PTY sessions
          {GSMLG.Commander.SessionManager, []},
          # WebSocket connection
          {Phoenix.SocketClient, socket_opts() ++ [name: GSMLG.Commander.Socket]},
          # Legacy channels (backward compatibility)
          {GSMLG.Commander.GreatHall, []},
          {GSMLG.Commander.Office, []},
          # New PTY terminal channel
          {GSMLG.Commander.Terminal, [socket: GSMLG.Commander.Socket, name: config[:name]]},
          # Legacy resource manager (kept for compatibility)
          {GSMLG.Commander.Resource, []}
        ]
      else
        []
      end

    children = server_children ++ agent_children

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
