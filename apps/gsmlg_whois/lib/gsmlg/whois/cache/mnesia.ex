defmodule GSMLG.Whois.Cache.Mnesia do
  @moduledoc """
  Mnesia-backed cache backend for GSMLG.Whois.

  Assumes Mnesia is already started by the host application. Create the
  table before use (typically in a release migration or application start):

      :mnesia.create_table(:gsmlg_whois_cache, [
        attributes: [:key, :value, :expires_at],
        type: :set,
        storage_properties: [ram_copies: [node()]]
      ])

  Uses `dirty_read`/`dirty_write` for low latency without transactions.
  Expiry is checked lazily on `get/1` — no background cleanup process needed.
  """

  @behaviour GSMLG.Whois.Cache

  @table :gsmlg_whois_cache

  @impl GSMLG.Whois.Cache
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :mnesia.dirty_read(@table, key) do
      [{@table, ^key, value, expires_at}] when now < expires_at ->
        {:ok, value}

      [{@table, ^key, _value, _expired}] ->
        :mnesia.dirty_delete(@table, key)
        :miss

      [] ->
        :miss
    end
  end

  @impl GSMLG.Whois.Cache
  def put(key, value, _type, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :mnesia.dirty_write({@table, key, value, expires_at})
    :ok
  end

  @impl GSMLG.Whois.Cache
  def delete(key) do
    :mnesia.dirty_delete(@table, key)
    :ok
  end

  @impl GSMLG.Whois.Cache
  def clear do
    {:atomic, :ok} = :mnesia.clear_table(@table)
    :ok
  end
end
