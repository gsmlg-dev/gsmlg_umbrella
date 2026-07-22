defmodule GSMLG.ProxyRules.Application do
  use Application

  @impl true
  def start(_type, _args), do: GSMLG.ProxyRules.Supervisor.start_link([])
end
