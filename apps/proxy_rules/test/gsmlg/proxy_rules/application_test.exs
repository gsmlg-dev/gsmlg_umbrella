defmodule GSMLG.ProxyRules.ApplicationTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.SourceSnapshot

  test "starts the fixed one-for-one supervision tree" do
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Supervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.TaskSupervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Store))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Source.Remote))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Source.Local))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Coordinator))

    assert %{active: 5, specs: 5, supervisors: 1, workers: 4} =
             Supervisor.count_children(GSMLG.ProxyRules.Supervisor)

    assert %{} = GSMLG.ProxyRules.Source.Local.snapshots(GSMLG.ProxyRules.Source.Local)

    assert GSMLG.ProxyRules.Source.Remote.snapshot(GSMLG.ProxyRules.Source.Remote) in [nil] or
             match?(
               %SourceSnapshot{},
               GSMLG.ProxyRules.Source.Remote.snapshot(GSMLG.ProxyRules.Source.Remote)
             )
  end
end
