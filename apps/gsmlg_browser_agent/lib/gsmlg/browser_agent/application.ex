defmodule GSMLG.BrowserAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    GSMLG.BrowserAgent.Supervisor.start_link([])
  end
end
