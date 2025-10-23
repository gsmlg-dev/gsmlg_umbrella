defmodule GSMLG.Telemetry.Handler do
  @moduledoc """
  Telemetry event handler for GSMLG applications.

  This module handles telemetry events and forwards them to appropriate backends
  for logging and metrics collection.
  """

  use GenServer
  require Logger

  alias GSMLG.Telemetry.{Metrics, Reporter}
  alias GSMLG.Telemetry.Backends.{Console, File, CloudWatch}

  @default_events [
    [:gsmlg, :log],
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :start],
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :repo, :query],
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :start],
    [:phoenix, :live_view, :handle_params, :stop],
    [:ecto, :repo, :query],
    [:ecto, :db, :query],
    [:vm, :memory],
    [:vm, :total_run_queue_lengths],
    [:vm, :system_counts]
  ]

  defstruct [:handlers, :config]

  @doc """
  Start the telemetry handler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry) |> Keyword.merge(opts)
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Attach a telemetry handler.
  """
  @spec attach(atom(), [atom()] | atom(), atom(), any()) :: :ok | {:error, :already_exists}
  def attach(handler_id, event_name, handler_module, handler_config \\ %{}) do
    :telemetry.attach_many(
      handler_id,
      List.wrap(event_name),
      &handler_module.handle_event/4,
      handler_config
    )
  end

  @doc """
  Detach a telemetry handler.
  """
  @spec detach(atom()) :: :ok | {:error, :not_found}
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  @impl true
  def init(config) do
    # Attach default handlers
    handlers = attach_default_handlers(config)

    {:ok, %__MODULE__{handlers: handlers, config: config}}
  end

  @impl true
  def handle_cast(
        {:attach_handler, handler_id, event_name, handler_module, handler_config},
        state
      ) do
    case attach(handler_id, event_name, handler_module, handler_config) do
      :ok ->
        {:noreply, %{state | handlers: [handler_id | state.handlers]}}

      {:error, :already_exists} ->
        Logger.warning("Handler #{handler_id} already exists")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:detach_handler, handler_id}, state) do
    case detach(handler_id) do
      :ok ->
        {:noreply, %{state | handlers: List.delete(state.handlers, handler_id)}}

      {:error, :not_found} ->
        Logger.warning("Handler #{handler_id} not found")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconfigure, state) do
    # Detach all current handlers
    Enum.each(state.handlers, &detach/1)

    # Reattach handlers with new config
    new_config = Application.get_all_env(:gsmlg_telemetry)
    handlers = attach_default_handlers(new_config)

    {:noreply, %__MODULE__{handlers: handlers, config: new_config}}
  end

  # Default event handler function
  def handle_event(event_name, measurements, metadata, _config) do
    # Forward to metrics collector
    Metrics.record_event(event_name, measurements, metadata)

    # Forward to reporter
    Reporter.handle_event(event_name, measurements, metadata)

    # Forward to enabled backends
    forward_to_backends(event_name, measurements, metadata)
  end

  defp attach_default_handlers(config) do
    events = Keyword.get(config, :events, @default_events)
    handlers_config = Keyword.get(config, :handlers, [])

    # Attach our main handler
    :ok = attach(:gsmlg_telemetry_main_handler, events, __MODULE__, %{})

    # Attach additional handlers from config
    additional_handlers =
      Enum.map(handlers_config, fn handler_config ->
        handler_id = Keyword.get(handler_config, :id)
        event_names = Keyword.get(handler_config, :events)
        handler_module = Keyword.get(handler_config, :module)
        handler_opts = Keyword.get(handler_config, :config, %{})

        case attach(handler_id, event_names, handler_module, handler_opts) do
          :ok ->
            handler_id

          {:error, :already_exists} ->
            Logger.warning("Handler #{handler_id} already exists, skipping")
            nil
        end
      end)

    [:gsmlg_telemetry_main_handler | Enum.filter(additional_handlers, & &1)]
  end

  defp forward_to_backends(event_name, measurements, metadata) do
    config = Application.get_all_env(:gsmlg_telemetry)
    backends_config = Keyword.get(config, :backends, [])

    # Forward to console backend
    if Keyword.get(backends_config, :console, []) |> Keyword.get(:enabled, true) do
      Console.handle_event(event_name, measurements, metadata)
    end

    # Forward to file backend
    if Keyword.get(backends_config, :file, []) |> Keyword.get(:enabled, false) do
      File.handle_event(event_name, measurements, metadata)
    end

    # Forward to CloudWatch backend
    if Keyword.get(backends_config, :cloudwatch, []) |> Keyword.get(:enabled, false) do
      CloudWatch.handle_event(event_name, measurements, metadata)
    end
  end

  @doc """
  Reconfigure the handler with new configuration.
  """
  @spec reconfigure() :: :ok
  def reconfigure do
    GenServer.cast(__MODULE__, :reconfigure)
  end

  @doc """
  Attach an additional handler at runtime.
  """
  @spec attach_handler(atom(), [atom()] | atom(), atom(), any()) :: :ok
  def attach_handler(handler_id, event_name, handler_module, handler_config) do
    GenServer.cast(
      __MODULE__,
      {:attach_handler, handler_id, event_name, handler_module, handler_config}
    )
  end

  @doc """
  Detach a handler at runtime.
  """
  @spec detach_handler(atom()) :: :ok
  def detach_handler(handler_id) do
    GenServer.cast(__MODULE__, {:detach_handler, handler_id})
  end

  @doc """
  Get the list of currently attached handlers.
  """
  @spec list_handlers() :: [atom()]
  def list_handlers do
    GenServer.call(__MODULE__, :list_handlers)
  end

  @impl true
  def handle_call(:list_handlers, _from, state) do
    {:reply, state.handlers, state}
  end
end
