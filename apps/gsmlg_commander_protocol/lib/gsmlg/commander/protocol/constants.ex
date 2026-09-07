defmodule GSMLG.Commander.Protocol.Constants do
  @moduledoc false

  @protocol_version 1
  @browser_control_id "browser.control"
  @browser_control_version 1
  @browser_control_operations [
    "manager.status",
    "profiles.list",
    "profile.status",
    "profile.launch",
    "profile.stop",
    "session.open",
    "session.observe",
    "session.act",
    "session.manual_acquire",
    "session.manual_release",
    "session.close",
    "workflow.start",
    "workflow.status",
    "workflow.cancel",
    "workflow.resume",
    "workflow.reconcile",
    "artifact.fetch_inline",
    "artifact.upload",
    "artifact.ack"
  ]
  @workflow_events [
    "workflow.accepted",
    "workflow.started",
    "workflow.phase_changed",
    "intervention.required",
    "intervention.cleared",
    "artifact.available",
    "result.available",
    "workflow.failed",
    "workflow.cancelled",
    "workflow.completed"
  ]
  @pty_id "pty.shell"
  @pty_version 1

  def protocol_version, do: @protocol_version
  def browser_control_id, do: @browser_control_id
  def browser_control_version, do: @browser_control_version
  def browser_control_operations, do: @browser_control_operations
  def workflow_events, do: @workflow_events

  def capability_versions,
    do: %{@browser_control_id => @browser_control_version, @pty_id => @pty_version}

  def operations(@browser_control_id), do: @browser_control_operations
  def operations(@pty_id), do: []
  def operations(_unknown), do: nil
end
