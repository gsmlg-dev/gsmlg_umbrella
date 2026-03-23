defmodule GSMLG.Whois.Cache.Concord do
  @moduledoc """
  Concord-backed cache backend for GSMLG.Whois.

  Requires the `concord` hex package (`~> 0.1`) and Concord to be started
  by the host application.

  Concord's `ttl:` option accepts seconds (integer). This backend converts
  the behaviour's `ttl_ms` (milliseconds) to seconds automatically.

  Configuration:

      config :gsmlg_whois, cache: GSMLG.Whois.Cache.Concord

  Ensure Concord is started before use:

      Concord.start_link([])  # or add to supervision tree
  """

  @behaviour GSMLG.Whois.Cache

  @impl GSMLG.Whois.Cache
  def get(key) do
    case Concord.get(key) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> :miss
      {:error, _} -> :miss
      nil -> :miss
    end
  end

  @impl GSMLG.Whois.Cache
  def put(key, value, _type, ttl_ms) do
    ttl_secs = max(1, div(ttl_ms, 1_000))

    case Concord.put(key, value, ttl: ttl_secs) do
      {:ok, _} -> :ok
      :ok -> :ok
      _ -> :ok
    end
  end

  @impl GSMLG.Whois.Cache
  def delete(key) do
    case Concord.delete(key) do
      {:ok, _} -> :ok
      :ok -> :ok
      _ -> :ok
    end
  end

  @impl GSMLG.Whois.Cache
  def clear do
    case Concord.get_all() do
      {:ok, map} when map != %{} ->
        Concord.delete_many(Map.keys(map))
        :ok

      _ ->
        :ok
    end
  end
end
