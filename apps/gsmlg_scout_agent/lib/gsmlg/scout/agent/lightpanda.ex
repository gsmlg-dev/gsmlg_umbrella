defmodule GSMLG.Scout.Agent.Lightpanda do
  @moduledoc """
  Lightpanda adapter boundary.
  """

  @callback fetch(String.t(), map()) :: {:ok, map()} | {:error, map()}

  def fetch(url, opts \\ %{}) do
    adapter().fetch(url, opts)
  end

  defp adapter do
    Application.get_env(:gsmlg_scout_agent, :lightpanda_adapter, GSMLG.Scout.Agent.Lightpanda.CLI)
  end
end
