defmodule GSMLG.CommandPlatform.ReplayCache do
  @moduledoc "Atomic TTL cache used for authentication nonces and late RPC response replay."

  use GenServer

  @default_ttl_ms :timer.minutes(10)
  @default_max_entries 10_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def claim(server \\ __MODULE__, key, ttl_ms \\ @default_ttl_ms) do
    GenServer.call(server, {:claim, key, ttl_ms})
  end

  def put(server \\ __MODULE__, key, value, ttl_ms \\ @default_ttl_ms) do
    GenServer.call(server, {:put, key, value, ttl_ms})
  end

  def put_if_absent(key, value, ttl_ms \\ @default_ttl_ms) do
    put_if_absent(__MODULE__, key, value, ttl_ms)
  end

  def put_if_absent(server, key, value, ttl_ms) do
    GenServer.call(server, {:put_if_absent, key, value, ttl_ms})
  end

  def refresh(key, ttl_ms \\ @default_ttl_ms), do: refresh(__MODULE__, key, ttl_ms)
  def refresh(server, key, ttl_ms), do: GenServer.call(server, {:refresh, key, ttl_ms})

  def fetch(server \\ __MODULE__, key), do: GenServer.call(server, {:fetch, key})

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:claim, key, ttl_ms}, _from, state) do
    {entries, now} = prune(state)

    cond do
      Map.has_key?(entries, key) ->
        {:reply, {:error, :already_claimed}, %{state | entries: entries}}

      map_size(entries) >= state.max_entries ->
        {:reply, {:error, :capacity_reached}, %{state | entries: entries}}

      true ->
        entry = %{value: :claimed, expires_at: now + ttl_ms}
        {:reply, :ok, %{state | entries: Map.put(entries, key, entry)}}
    end
  end

  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    {entries, now} = prune(state)

    if Map.has_key?(entries, key) or map_size(entries) < state.max_entries do
      entry = %{value: value, expires_at: now + ttl_ms}
      {:reply, :ok, %{state | entries: Map.put(entries, key, entry)}}
    else
      {:reply, {:error, :capacity_reached}, %{state | entries: entries}}
    end
  end

  def handle_call({:put_if_absent, key, value, ttl_ms}, _from, state) do
    {entries, now} = prune(state)

    case Map.fetch(entries, key) do
      {:ok, %{value: existing}} ->
        {:reply, {:exists, existing}, %{state | entries: entries}}

      :error ->
        if map_size(entries) < state.max_entries do
          entry = %{value: value, expires_at: now + ttl_ms}
          {:reply, :ok, %{state | entries: Map.put(entries, key, entry)}}
        else
          {:reply, {:error, :capacity_reached}, %{state | entries: entries}}
        end
    end
  end

  def handle_call({:refresh, key, ttl_ms}, _from, state) do
    {entries, now} = prune(state)

    case Map.fetch(entries, key) do
      {:ok, entry} ->
        refreshed = %{entry | expires_at: now + ttl_ms}
        {:reply, :ok, %{state | entries: Map.put(entries, key, refreshed)}}

      :error ->
        {:reply, :error, %{state | entries: entries}}
    end
  end

  def handle_call({:fetch, key}, _from, state) do
    {entries, _now} = prune(state)

    reply =
      case Map.fetch(entries, key) do
        {:ok, %{value: value}} -> {:ok, value}
        :error -> :error
      end

    {:reply, reply, %{state | entries: entries}}
  end

  defp prune(state) do
    now = state.clock.()
    {Map.reject(state.entries, fn {_key, entry} -> entry.expires_at <= now end), now}
  end
end
