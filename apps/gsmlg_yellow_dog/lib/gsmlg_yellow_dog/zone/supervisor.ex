defmodule GSMLGYellowDog.Zone.Supervisor do
  @moduledoc """
  Example implementing GSMLGDNS.Zone behaviour
  """
  use DynamicSupervisor

  @spec start_link(any) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec start_child(any) :: :ignore | {:error, any} | {:ok, pid} | {:ok, pid, any}
  def start_child(zone) do
    DynamicSupervisor.start_child(__MODULE__, {GSMLGYellowDog.Zone.AuthZone, [zone]})
  end

  @impl true
  def init(init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: [init_arg]
    )
  end
end
