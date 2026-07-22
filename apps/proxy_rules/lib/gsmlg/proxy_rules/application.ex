defmodule GSMLG.ProxyRules.Application do
  use Application

  @impl true
  def start(_type, args), do: GSMLG.ProxyRules.Supervisor.start_link(args)
end
