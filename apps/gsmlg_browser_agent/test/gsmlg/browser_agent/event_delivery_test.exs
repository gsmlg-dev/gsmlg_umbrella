defmodule GSMLG.BrowserAgent.EventDeliveryTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{EventDelivery, Journal}
  alias GSMLG.Commander.Protocol.{EventAck, JobEvent}

  @moduletag :tmp_dir
  @execution_id "00000000-0000-4000-8000-000000000077"
  @job_id "00000000-0000-4000-8000-000000000177"

  setup %{tmp_dir: tmp_dir} do
    dets = String.to_atom("event_delivery_#{System.unique_integer([:positive])}")
    path = Path.join(tmp_dir, "events.dets")
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets)

    event = %{
      "type" => "job.event",
      "protocol_version" => 1,
      "remote_execution_id" => @execution_id,
      "event" => "workflow.started",
      "phase" => "inspect_auth",
      "metadata" => %{"central_job_id" => @job_id},
      "occurred_at" => "2026-09-06T00:00:00Z"
    }

    {:ok, _event} = Journal.append_event_once(journal, @execution_id, "started", event)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(dets)
    end)

    %{journal: journal, path: path, dets: dets}
  end

  test "disconnect preserves events and a restarted sender replays in order until ACK", ctx do
    parent = self()
    {:ok, connection} = Agent.start_link(fn -> :disconnected end)
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-06 00:00:00Z] end)

    sender = fn %JobEvent{} = event, connection ->
      case Agent.get(connection, & &1) do
        :connected ->
          send(parent, {:delivered, event.sequence, event.remote_execution_id})
          :ok

        :disconnected ->
          {:error, :not_joined}
      end
    end

    {:ok, delivery} =
      EventDelivery.start_link(
        name: nil,
        journal: ctx.journal,
        connection: connection,
        sender: sender,
        interval_ms: :timer.hours(1)
      )

    assert {:error, :not_joined} = EventDelivery.deliver_now(delivery)
    assert [%{"sequence" => 1}] = Journal.event_unacked(ctx.journal, @execution_id)
    assert {:error, :event_ack_ahead} = Journal.ack_events(ctx.journal, @execution_id, 1)

    GenServer.stop(delivery)
    GenServer.stop(ctx.journal)

    Agent.update(clock, &DateTime.add(&1, 30, :minute))
    assert Agent.get(clock, & &1) == ~U[2026-09-06 00:30:00Z]

    {:ok, reopened} = Journal.start_link(name: nil, path: ctx.path, dets_name: ctx.dets)
    Agent.update(connection, fn _ -> :connected end)

    {:ok, restarted} =
      EventDelivery.start_link(
        name: nil,
        journal: reopened,
        connection: connection,
        sender: sender,
        interval_ms: :timer.hours(1)
      )

    assert :ok = EventDelivery.deliver_now(restarted)
    assert_receive {:delivered, 1, @execution_id}

    assert :ok =
             EventDelivery.ack(
               restarted,
               %EventAck{
                 protocol_version: 1,
                 remote_execution_id: @execution_id,
                 highest_contiguous_sequence: 1
               }
             )

    assert [] = Journal.event_unacked(reopened, @execution_id)
    GenServer.stop(restarted)
    GenServer.stop(reopened)
    Agent.stop(clock)
  end

  test "invalid and cross-execution ACKs never prune the durable outbox", ctx do
    {:ok, delivery} =
      EventDelivery.start_link(
        name: nil,
        journal: ctx.journal,
        connection: self(),
        sender: fn _event, _connection -> :ok end,
        interval_ms: :timer.hours(1)
      )

    assert :ok = EventDelivery.deliver_now(delivery)

    assert {:error, :event_execution_not_found} =
             EventDelivery.ack(
               delivery,
               %EventAck{
                 protocol_version: 1,
                 remote_execution_id: "00000000-0000-4000-8000-000000000078",
                 highest_contiguous_sequence: 1
               }
             )

    assert [%{"sequence" => 1}] = Journal.event_unacked(ctx.journal, @execution_id)
  end
end
