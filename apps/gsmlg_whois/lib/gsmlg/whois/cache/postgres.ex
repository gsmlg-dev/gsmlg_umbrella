defmodule GSMLG.Whois.Cache.Postgres do
  @moduledoc """
  PostgreSQL-backed cache backend for GSMLG.Whois.

  Requires the `postgrex` package and a running Postgrex connection pool.
  Configure the pool name:

      config :gsmlg_whois, cache_postgres_conn: :whois_cache_conn

  Start the pool in your supervision tree:

      Postgrex.start_link(
        name: :whois_cache_conn,
        hostname: "localhost",
        database: "myapp",
        username: "myuser",
        password: "mypassword"
      )

  Create the cache table before use:

      CREATE TABLE IF NOT EXISTS gsmlg_whois_cache (
        key TEXT PRIMARY KEY,
        value BYTEA NOT NULL,
        expires_at BIGINT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_gsmlg_whois_cache_expires_at
        ON gsmlg_whois_cache (expires_at);

  Values are serialized with `:erlang.term_to_binary/1` and stored as BYTEA.
  Expiry is checked lazily on `get/1`. Run periodic cleanup externally:

      DELETE FROM gsmlg_whois_cache WHERE expires_at < extract(epoch from now()) * 1000;
  """

  @behaviour GSMLG.Whois.Cache

  @table "gsmlg_whois_cache"

  @impl GSMLG.Whois.Cache
  def get(key) do
    conn = conn()
    now = System.monotonic_time(:millisecond)
    sql = "SELECT value, expires_at FROM #{@table} WHERE key = $1"

    case Postgrex.query(conn, sql, [key]) do
      {:ok, %{rows: [[value_bin, expires_at]]}} ->
        if now < expires_at do
          {:ok, :erlang.binary_to_term(value_bin)}
        else
          delete(key)
          :miss
        end

      {:ok, %{rows: []}} ->
        :miss

      {:error, _reason} ->
        :miss
    end
  end

  @impl GSMLG.Whois.Cache
  def put(key, value, _type, ttl_ms) do
    conn = conn()
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    value_bin = :erlang.term_to_binary(value)

    sql = """
    INSERT INTO #{@table} (key, value, expires_at)
    VALUES ($1, $2, $3)
    ON CONFLICT (key) DO UPDATE SET value = $2, expires_at = $3
    """

    case Postgrex.query(conn, sql, [key, value_bin, expires_at]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @impl GSMLG.Whois.Cache
  def delete(key) do
    conn = conn()
    sql = "DELETE FROM #{@table} WHERE key = $1"

    case Postgrex.query(conn, sql, [key]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @impl GSMLG.Whois.Cache
  def clear do
    conn = conn()
    sql = "TRUNCATE #{@table}"

    case Postgrex.query(conn, sql, []) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp conn do
    Application.get_env(:gsmlg_whois, :cache_postgres_conn, :gsmlg_whois_pg_cache)
  end
end
