defmodule GSMLG.Commander.Resource do
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def hire_peon() do
    # spec = %{id: CourseState, start: {DeployState, :start_link, []}}
    # DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def dismissal_peon() do
    # spec = %{id: CourseState, start: {DeployState, :start_link, []}}
    # DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec units_info() :: %{
          specs: non_neg_integer(),
          active: non_neg_integer(),
          supervisors: non_neg_integer(),
          workers: non_neg_integer()
        }
  def units_info() do
    DynamicSupervisor.count_children(__MODULE__)
  end
end
