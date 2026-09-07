defmodule GSMLG.BrowserAgent.Session do
  @moduledoc "Safe browser session lifecycle facade."

  alias GSMLG.BrowserAgent.SessionSupervisor

  def open(supervisor \\ SessionSupervisor, params),
    do: SessionSupervisor.open(supervisor, params)

  @doc false
  def open_workflow(supervisor \\ SessionSupervisor, params),
    do: SessionSupervisor.open_workflow(supervisor, params)

  def observe(supervisor \\ SessionSupervisor, session_id),
    do: SessionSupervisor.call(supervisor, session_id, :observe)

  def act(supervisor \\ SessionSupervisor, session_id, action),
    do: SessionSupervisor.call(supervisor, session_id, {:act, action})

  def manual_handoff(supervisor \\ SessionSupervisor, session_id, operator_id),
    do: SessionSupervisor.call(supervisor, session_id, {:manual_handoff, operator_id})

  def manual_acquire(supervisor \\ SessionSupervisor, session_id, operator_id),
    do: SessionSupervisor.call(supervisor, session_id, {:manual_acquire, operator_id})

  def manual_release(supervisor \\ SessionSupervisor, session_id, lease_id, operator_id),
    do:
      SessionSupervisor.call(
        supervisor,
        session_id,
        {:manual_release, lease_id, operator_id}
      )

  def resume_automation(supervisor \\ SessionSupervisor, session_id),
    do: SessionSupervisor.call(supervisor, session_id, :resume_automation)

  def close(supervisor \\ SessionSupervisor, session_id),
    do: SessionSupervisor.call(supervisor, session_id, :close)

  def reconcile(supervisor \\ SessionSupervisor, session_id),
    do: SessionSupervisor.call(supervisor, session_id, :reconcile)
end
