defmodule GSMLG.ProxyRules.Store do
  use GenServer

  @table :gsmlg_proxy_rules_store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end
end
