defmodule GSMLG.ProxyRules.Store do
  use GenServer

  @table :gsmlg_proxy_rules_store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec current() :: {:ok, map()} | {:error, :not_ready}
  def current do
    case :ets.lookup(@table, :current) do
      [{:current, snapshot}] when is_map(snapshot) -> {:ok, snapshot}
      [] -> {:error, :not_ready}
    end
  rescue
    ArgumentError -> {:error, :not_ready}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end
end
