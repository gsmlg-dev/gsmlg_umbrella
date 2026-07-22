defmodule GSMLG.ProxyRules.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts the fixed one-for-one supervision tree" do
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Supervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.TaskSupervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Store))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Coordinator))

    assert %{active: 3, specs: 3, supervisors: 1, workers: 2} =
             Supervisor.count_children(GSMLG.ProxyRules.Supervisor)
  end
end
