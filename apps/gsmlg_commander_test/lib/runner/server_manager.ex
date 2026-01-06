defmodule GSMLG.CommanderTest.Runner.ServerManager do
  @moduledoc """
  Manages Commander server lifecycle for E2E testing.

  Starts the actual gsmlg_commander application on a test port,
  waits for it to be ready, and stops it cleanly.

  ## Usage

      # Start server on default port
      {:ok, server} = ServerManager.start_server()

      # Start server on custom port
      {:ok, server} = ServerManager.start_server(port: 15000)

      # Check health
      :ok = ServerManager.health_check(14000)

      # Stop server
      :ok = ServerManager.stop_server()

  """

  use GenServer

  require Logger

  @default_port 14000
  @health_check_timeout 10_000
  @health_check_interval 100

  defstruct [:port, :status, :ws_url, :started_at]

  # Client API

  @doc """
  Start the Commander server for testing.

  ## Options

    * `:port` - Port to run the server on (default: 14000)
    * `:config` - Additional server configuration

  ## Returns

    * `{:ok, %{port: port, ws_url: url}}` - Server started successfully
    * `{:error, reason}` - Failed to start server

  """
  @spec start_server(keyword()) :: {:ok, map()} | {:error, term()}
  def start_server(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    config = Keyword.get(opts, :config, [])

    # Configure the Commander application for testing
    configure_for_test(port, config)

    # Start the Commander application
    case Application.ensure_all_started(:gsmlg_commander) do
      {:ok, _apps} ->
        # Wait for server to be ready
        case wait_for_health_check(port) do
          :ok ->
            server_info = %{
              port: port,
              ws_url: get_ws_url(port),
              started_at: DateTime.utc_now()
            }

            {:ok, server_info}

          {:error, reason} ->
            # Cleanup on failure
            Application.stop(:gsmlg_commander)
            {:error, {:health_check_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  @doc """
  Stop the Commander server.
  """
  @spec stop_server() :: :ok
  def stop_server do
    Application.stop(:gsmlg_commander)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Get WebSocket URL for agent connections.
  """
  @spec get_ws_url(integer()) :: String.t()
  def get_ws_url(port \\ @default_port) do
    "ws://localhost:#{port}/agent/connect"
  end

  @doc """
  Check server health.

  ## Returns

    * `:ok` - Server is healthy
    * `{:error, reason}` - Server is not healthy

  """
  @spec health_check(integer()) :: :ok | {:error, term()}
  def health_check(port \\ @default_port) do
    url = ~c"http://localhost:#{port}/health"

    case :httpc.request(:get, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:unhealthy, status, body}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # Private functions

  defp configure_for_test(port, config) do
    # Set test-specific configuration for Commander
    # This configures shorter timeouts for faster testing

    idle_timeout = Keyword.get(config, :idle_timeout, :timer.seconds(30))
    grace_period = Keyword.get(config, :reconnect_grace_period, :timer.seconds(10))
    heartbeat = Keyword.get(config, :heartbeat_interval, :timer.seconds(5))

    Application.put_env(:gsmlg_commander, :port, port)
    Application.put_env(:gsmlg_commander, :idle_timeout, idle_timeout)
    Application.put_env(:gsmlg_commander, :reconnect_grace_period, grace_period)
    Application.put_env(:gsmlg_commander, :heartbeat_interval, heartbeat)
    Application.put_env(:gsmlg_commander, :test_mode, true)
  end

  defp wait_for_health_check(port, timeout \\ @health_check_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_health_check(port, deadline)
  end

  defp do_wait_for_health_check(port, deadline) do
    case health_check(port) do
      :ok ->
        :ok

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@health_check_interval)
          do_wait_for_health_check(port, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  # GenServer callbacks (for potential future use with state management)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      port: Keyword.get(opts, :port, @default_port),
      status: :stopped
    }

    {:ok, state}
  end
end
