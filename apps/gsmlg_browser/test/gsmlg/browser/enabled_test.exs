defmodule GSMLG.Browser.EnabledTest do
  use GSMLG.Browser.DataCase, async: false

  alias GSMLG.Browser
  alias GSMLG.Browser.{ArtifactService, Error}
  alias GSMLG.Commander.Protocol.JobEvent

  test "public facade, event ingress, and artifact ingress fail closed when disabled" do
    previous = Application.get_env(:gsmlg_browser, :enabled)
    Application.put_env(:gsmlg_browser, :enabled, false)
    on_exit(fn -> Application.put_env(:gsmlg_browser, :enabled, previous) end)

    actor = %{id: Ecto.UUID.generate()}

    assert {:error,
            %Error{
              class: "availability",
              code: "service_unavailable",
              retryable: true,
              details: %{}
            }} = Browser.list_nodes(actor, [])

    event = %JobEvent{
      protocol_version: 1,
      remote_execution_id: Ecto.UUID.generate(),
      sequence: 1,
      event: "workflow.started",
      phase: nil,
      metadata: %{"central_job_id" => Ecto.UUID.generate()},
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:error, :service_unavailable} =
             GSMLG.Browser.EventStore.ingest("agent", event)

    assert {:error, :service_unavailable} =
             ArtifactService.begin_upload(Ecto.UUID.generate(), "token", %{})
  end
end
