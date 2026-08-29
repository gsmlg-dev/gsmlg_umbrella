defmodule GSMLG.Telemetry.Handler do
  @moduledoc """
  Telemetry event handler for GSMLG applications.

  This module handles telemetry events and forwards them to appropriate backends
  for logging and metrics collection.
  """

  use GenServer
  require Logger

  alias GSMLG.Telemetry.{Metrics, Reporter}
  alias GSMLG.Telemetry.Backends.{Console, File}
  # CloudWatch backend disabled - see cloudwatch.ex

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
    [:gsmlg, :repo, :query],
    [:ecto, :repo, :query],
    [:ecto, :db, :query],
    [:vm, :memory],
    [:vm, :total_run_queue_lengths],
    [:vm, :system_counts]
  ]

  @max_metadata_binary_bytes 512
  @max_custom_metadata_entries 32
  @max_custom_metadata_depth 4
  @max_custom_metadata_nodes 256
  @sensitive_metadata_key_segments ~w(
    password
    token
    authorization
    cookie
    session
    certificate
    certificate_der
    pem
    params
    body_params
    headers
    conn
    socket
    assigns
    private
    query
    result
    subject
    email
  )
  @safe_metadata_keys ~w(connection_state reconnect_count result_count fingerprint)

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
    metadata = sanitize_metadata(event_name, metadata)

    # Forward to metrics collector
    Metrics.record_event(event_name, measurements, metadata)

    # Forward to reporter
    Reporter.handle_event(event_name, measurements, metadata)

    # Forward to enabled backends
    forward_to_backends(event_name, measurements, metadata)
  end

  defp sanitize_metadata([:phoenix, :endpoint, phase], metadata)
       when phase in [:start, :stop] do
    sanitize_endpoint_metadata(metadata)
  end

  defp sanitize_metadata([:phoenix, :router_dispatch, phase], metadata)
       when phase in [:start, :stop] do
    metadata
    |> take_safe_metadata([:route, :plug, :plug_opts, :action])
    |> require_atom_metadata([:plug, :plug_opts, :action])
  end

  defp sanitize_metadata([:phoenix, :live_view, lifecycle, phase], metadata)
       when lifecycle in [:mount, :handle_params] and phase in [:start, :stop] do
    sanitize_live_view_metadata(metadata)
  end

  defp sanitize_metadata([:phoenix, :repo, :query], metadata) do
    sanitize_repo_query_metadata(metadata)
  end

  defp sanitize_metadata([:gsmlg, :repo, :query], metadata) do
    sanitize_repo_query_metadata(metadata)
  end

  defp sanitize_metadata([:ecto, repo_event, :query], metadata)
       when repo_event in [:repo, :db] do
    sanitize_repo_query_metadata(metadata)
  end

  defp sanitize_metadata(_event_name, metadata) do
    case sanitize_custom_value(metadata, 0, @max_custom_metadata_nodes) do
      {:ok, sanitized, _remaining_budget} when is_map(sanitized) -> sanitized
      _other -> %{}
    end
  end

  defp sanitize_repo_query_metadata(metadata) do
    metadata
    |> take_safe_metadata([:repo, :source, :type])
    |> require_atom_metadata([:repo, :type])
  end

  defp sanitize_endpoint_metadata(%{conn: conn}) when is_map(conn) do
    %{}
    |> put_safe_metadata(:method, Map.get(conn, :method))
    |> put_safe_metadata(:request_path, Map.get(conn, :request_path))
    |> put_safe_metadata(:status, Map.get(conn, :status))
    |> put_safe_metadata(:request_id, request_id_from_conn(conn))
  end

  defp sanitize_endpoint_metadata(_metadata), do: %{}

  defp sanitize_live_view_metadata(%{socket: socket}) when is_map(socket) do
    assigns = Map.get(socket, :assigns, %{})
    action = if is_map(assigns), do: Map.get(assigns, :live_action), else: nil

    %{}
    |> put_atom_metadata(:view, Map.get(socket, :view))
    |> put_atom_metadata(:action, action)
  end

  defp sanitize_live_view_metadata(_metadata), do: %{}

  defp request_id_from_conn(%{resp_headers: headers}) when is_list(headers) do
    find_header(headers, "x-request-id", 0)
  end

  defp request_id_from_conn(_conn), do: nil

  defp find_header(_headers, _name, @max_custom_metadata_entries), do: nil
  defp find_header([], _name, _count), do: nil

  defp find_header([{name, value} | _headers], name, _count) when is_binary(value),
    do: value

  defp find_header([_header | headers], name, count),
    do: find_header(headers, name, count + 1)

  defp find_header(_improper, _name, _count), do: nil

  defp put_safe_metadata(metadata, _key, nil), do: metadata

  defp put_safe_metadata(metadata, key, value) do
    if safe_scalar?(value), do: Map.put(metadata, key, value), else: metadata
  end

  defp put_atom_metadata(metadata, _key, nil), do: metadata

  defp put_atom_metadata(metadata, key, value) when is_atom(value),
    do: Map.put(metadata, key, value)

  defp put_atom_metadata(metadata, _key, _value), do: metadata

  defp take_safe_metadata(metadata, keys) when is_map(metadata) do
    Map.take(metadata, keys)
    |> Map.filter(fn {_key, value} -> safe_scalar?(value) end)
  end

  defp take_safe_metadata(_metadata, _keys), do: %{}

  defp require_atom_metadata(metadata, keys) do
    Map.filter(metadata, fn {key, value} -> key not in keys or is_atom(value) end)
  end

  defp safe_scalar?(value) when is_binary(value) do
    byte_size(value) <= @max_metadata_binary_bytes and String.valid?(value)
  end

  defp safe_scalar?(value) when is_atom(value) or is_integer(value), do: true
  defp safe_scalar?(_value), do: false

  defp sanitize_custom_value(_value, _depth, 0), do: {:drop, 0}

  defp sanitize_custom_value(value, _depth, budget) when is_binary(value) do
    remaining_budget = budget - 1

    if byte_size(value) <= @max_metadata_binary_bytes and String.valid?(value) do
      {:ok, value, remaining_budget}
    else
      {:drop, remaining_budget}
    end
  end

  defp sanitize_custom_value(value, _depth, budget)
       when is_atom(value) or is_integer(value),
       do: {:ok, value, budget - 1}

  defp sanitize_custom_value(value, _depth, budget) when is_struct(value),
    do: {:drop, budget - 1}

  defp sanitize_custom_value(value, depth, budget)
       when is_map(value) and depth < @max_custom_metadata_depth and
              map_size(value) <= @max_custom_metadata_entries do
    sanitize_custom_map(value, depth + 1, budget - 1)
  end

  defp sanitize_custom_value(value, depth, budget)
       when is_list(value) and depth < @max_custom_metadata_depth do
    sanitize_custom_list(value, depth + 1, 0, [], budget - 1)
  end

  defp sanitize_custom_value(_value, _depth, budget), do: {:drop, budget - 1}

  defp sanitize_custom_map(_map, _depth, 0), do: {:ok, %{}, 0}

  defp sanitize_custom_map(map, depth, budget) do
    {sanitized, remaining_budget} =
      Enum.reduce_while(map, {%{}, budget}, fn {key, nested_value}, {acc, remaining} ->
        cond do
          remaining == 0 ->
            {:halt, {acc, 0}}

          not safe_custom_key?(key) or sensitive_metadata_key?(key) ->
            continue_or_halt(acc, remaining - 1)

          true ->
            case sanitize_custom_value(nested_value, depth, remaining) do
              {:ok, safe_value, next_budget} ->
                continue_or_halt(Map.put(acc, key, safe_value), next_budget)

              {:drop, next_budget} ->
                continue_or_halt(acc, next_budget)
            end
        end
      end)

    {:ok, sanitized, remaining_budget}
  end

  defp continue_or_halt(acc, 0), do: {:halt, {acc, 0}}
  defp continue_or_halt(acc, budget), do: {:cont, {acc, budget}}

  defp sanitize_custom_list(_list, _depth, _count, acc, 0),
    do: {:ok, Enum.reverse(acc), 0}

  defp sanitize_custom_list([], _depth, _count, acc, budget),
    do: {:ok, Enum.reverse(acc), budget}

  defp sanitize_custom_list(
         [_head | _tail],
         _depth,
         @max_custom_metadata_entries,
         _acc,
         budget
       ),
       do: {:drop, budget}

  defp sanitize_custom_list([head | tail], depth, count, acc, budget) do
    case sanitize_custom_value(head, depth, budget) do
      {:ok, safe_value, next_budget} ->
        sanitize_custom_list(tail, depth, count + 1, [safe_value | acc], next_budget)

      {:drop, next_budget} ->
        sanitize_custom_list(tail, depth, count + 1, acc, next_budget)
    end
  end

  defp sanitize_custom_list(_improper, _depth, _count, _acc, budget), do: {:drop, budget}

  defp safe_custom_key?(key) when is_atom(key), do: true

  defp safe_custom_key?(key) when is_binary(key),
    do: byte_size(key) <= @max_metadata_binary_bytes and String.valid?(key)

  defp safe_custom_key?(_key), do: false

  defp sensitive_metadata_key?(key) do
    segments =
      key
      |> to_string()
      |> Macro.underscore()
      |> String.split(~r/[^a-z0-9]+/u, trim: true)

    normalized_key = Enum.join(segments, "_")

    normalized_key not in @safe_metadata_keys and
      Enum.any?(segments, &(&1 in @sensitive_metadata_key_segments))
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

    # CloudWatch backend disabled - see cloudwatch.ex for TODO
    # if Keyword.get(backends_config, :cloudwatch, []) |> Keyword.get(:enabled, false) do
    #   CloudWatch.handle_event(event_name, measurements, metadata)
    # end
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
