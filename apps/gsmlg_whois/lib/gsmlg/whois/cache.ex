defmodule GSMLG.Whois.Cache do
  @moduledoc """
  ETS-based caching layer for WHOIS lookups.

  Caches WHOIS responses to reduce network overhead and improve response times.
  Automatically expires entries based on configurable TTL values.

  ## Configuration

      config :gsmlg_whois,
        cache_enabled: true,
        cache_ttl: [
          domain: 86_400_000,  # 24 hours
          ip: 3_600_000,       # 1 hour
          asn: 3_600_000       # 1 hour
        ]

  ## Usage

      # Get cached entry
      case GSMLG.Whois.Cache.get("example.com") do
        {:ok, result} -> result
        :miss -> perform_lookup()
      end

      # Store in cache
      GSMLG.Whois.Cache.put("example.com", result, :domain)

      # Clear all cache
      GSMLG.Whois.Cache.clear()

      # Get cache statistics
      GSMLG.Whois.Cache.stats()
  """

  use GenServer
  require Logger

  @table_name :gsmlg_whois_cache
  @default_ttl %{
    domain: 86_400_000,
    ip: 3_600_000,
    asn: 3_600_000
  }

  # Client API
  # ----------

  @doc """
  Starts the cache GenServer.
  """
  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves a cached WHOIS result.

  Returns `{:ok, result}` if found and not expired, `:miss` otherwise.

  ## Examples

      iex> GSMLG.Whois.Cache.get("example.com")
      {:ok, "Domain Name: EXAMPLE.COM\\n..."}

      iex> GSMLG.Whois.Cache.get("nonexistent.com")
      :miss
  """
  @spec get(String.t()) :: {:ok, String.t()} | :miss
  def get(key) do
    if cache_enabled?() do
      case :ets.lookup(@table_name, key) do
        [{^key, value, expires_at}] ->
          now = System.monotonic_time(:millisecond)

          if now < expires_at do
            {:ok, value}
          else
            # Entry expired, delete it
            :ets.delete(@table_name, key)
            :miss
          end

        [] ->
          :miss
      end
    else
      :miss
    end
  end

  @doc """
  Stores a WHOIS result in the cache.

  ## Parameters

    - `key` - The lookup key (domain, IP, or ASN)
    - `value` - The WHOIS response string
    - `type` - One of `:domain`, `:ip`, or `:asn` (determines TTL)

  ## Examples

      iex> GSMLG.Whois.Cache.put("example.com", whois_result, :domain)
      :ok
  """
  @spec put(String.t(), String.t(), :domain | :ip | :asn) :: :ok
  def put(key, value, type) when type in [:domain, :ip, :asn] do
    if cache_enabled?() do
      ttl = get_ttl(type)
      expires_at = System.monotonic_time(:millisecond) + ttl
      :ets.insert(@table_name, {key, value, expires_at})
      :ok
    else
      :ok
    end
  end

  @doc """
  Clears all entries from the cache.

  ## Examples

      iex> GSMLG.Whois.Cache.clear()
      :ok
  """
  @spec clear() :: :ok
  def clear do
    if cache_enabled?() do
      :ets.delete_all_objects(@table_name)
      :ok
    else
      :ok
    end
  end

  @doc """
  Returns cache statistics.

  ## Examples

      iex> GSMLG.Whois.Cache.stats()
      %{
        size: 42,
        memory_bytes: 12345,
        enabled: true
      }
  """
  @spec stats() :: map()
  def stats do
    if cache_enabled?() do
      info = :ets.info(@table_name)

      %{
        size: info[:size] || 0,
        memory_bytes: (info[:memory] || 0) * :erlang.system_info(:wordsize),
        enabled: true
      }
    else
      %{size: 0, memory_bytes: 0, enabled: false}
    end
  end

  @doc """
  Checks if a key exists in the cache (regardless of expiration).

  Useful for testing and debugging.
  """
  @spec has_key?(String.t()) :: boolean()
  def has_key?(key) do
    if cache_enabled?() do
      case :ets.lookup(@table_name, key) do
        [] -> false
        _ -> true
      end
    else
      false
    end
  end

  # Server Callbacks
  # ----------------

  @impl true
  def init(_opts) do
    if cache_enabled?() do
      :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
      Logger.info("GSMLG.Whois.Cache started with table #{@table_name}")

      # Schedule periodic cleanup
      schedule_cleanup()
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    if cache_enabled?() do
      cleanup_expired()
      schedule_cleanup()
    end

    {:noreply, state}
  end

  # Private Helpers
  # ---------------

  defp cache_enabled? do
    Application.get_env(:gsmlg_whois, :cache_enabled, true)
  end

  defp get_ttl(type) do
    config_ttl = Application.get_env(:gsmlg_whois, :cache_ttl, %{})
    Map.get(config_ttl, type) || Map.get(@default_ttl, type)
  end

  defp schedule_cleanup do
    # Run cleanup every 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Find all expired entries
    expired_keys =
      :ets.foldl(
        fn {key, _value, expires_at}, acc ->
          if now >= expires_at do
            [key | acc]
          else
            acc
          end
        end,
        [],
        @table_name
      )

    # Delete expired entries
    Enum.each(expired_keys, fn key ->
      :ets.delete(@table_name, key)
    end)

    if length(expired_keys) > 0 do
      Logger.debug("GSMLG.Whois.Cache: Cleaned up #{length(expired_keys)} expired entries")
    end
  end
end
