defmodule GSMLG.Tor do
  @moduledoc """
  Starting a tor server in elixir using Port.

  The Tor Project [https://www.torproject.org](https://www.torproject.org)

  """

  alias GSMLG.Tor.Config
  require Logger
  use GenServer

  @doc """
  Start tor server at using config file return by `GSMLG.Tor.Config.torrc()`

  Start server with

  ```
  GSMLG.Tor.start()
  ```

  or add to supervisor tree
  ```
  {GSMLG.Tor, []}
  ```

  To start server, libevent must be installed.
  """
  def start() do
    GenServer.start(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Return GenServer state.

  `%{port: <port>}`

  """
  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Stop Tor server using system kill
  """
  def stop() do
    {:os_pid, pid} = get_state() |> Map.get(:port) |> Port.info(:os_pid)
    {_, code} = System.cmd("kill", ["#{pid}"])
    code
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_init) do
    state = %{port: nil}
    # your trap_exit call should be here
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :start_server}}
  end

  def handle_continue(:start_server, state) do
    Logger.info("Init Tor Config...")
    Config.init()

    Logger.info("Staring Tor Server...")

    port =
      Port.open(
        {:spawn_executable, cmd()},
        [
          {:args, ["-f", Config.torrc_file()]},
          {:cd, Application.app_dir(:gsmlg_tor, "priv/tor")},
          :stream,
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout
        ]
      )

    state = Map.put(state, :port, port)
    {:noreply, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_info({port, {:data, msg}}, state) do
    Logger.debug("Tor #{inspect(port)}: #{msg}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, exit_status}}, state) do
    Logger.info("Tor #{inspect(port)}: exit_status: #{exit_status}")
    {:noreply, state}
  end

  # handle the trapped exit call
  def handle_info({:EXIT, _from, reason}, state) do
    Logger.info("Tor exit: #{inspect(reason)}")
    cleanup(reason, state)
    # see GenServer docs for other return types
    {:stop, reason, state}
  end

  defp cleanup(_reason, state) do
    case state |> Map.get(:port) |> Port.info(:os_pid) do
      {:os_pid, pid} ->
        {_, code} = System.cmd("kill", ["#{pid}"])
        code

      _ ->
        0
    end
  end

  defp cmd() do
    Config.command_path()
  end
end
