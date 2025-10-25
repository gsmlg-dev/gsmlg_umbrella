defmodule GSMLG.PKI.EventsTest do
  use ExUnit.Case, async: false

  alias GSMLG.PKI.Events

  setup_all do
    # Setup CouchDB database for testing
    Application.put_env(:gsmlg_pki, GSMLG.PKI.Store.CouchDB, database: "pki_events_test")

    case GSMLG.PKI.Store.CouchDB.setup() do
      :ok -> :ok
      {:error, _} -> :ok
    end

    :ok
  end

  setup do
    test_id = :erlang.unique_integer([:positive])
    ca_id = "ca:test_#{test_id}"

    {:ok, ca_id: ca_id}
  end

  describe "Events.append/3" do
    test "appends a new event", %{ca_id: ca_id} do
      metadata = %{
        test_data: "value",
        serial: 12345
      }

      {:ok, event} =
        Events.append(:certificate_issued, metadata,
          ca_id: ca_id,
          actor: "test-user"
        )

      assert event.id != nil
      assert event.event_type == :certificate_issued
      assert event.ca_id == ca_id
      assert event.actor == "test-user"
      assert event.metadata.test_data == "value"
      assert event.sequence >= 1
    end

    test "increments sequence number", %{ca_id: ca_id} do
      {:ok, event1} = Events.append(:certificate_issued, %{}, ca_id: ca_id)
      {:ok, event2} = Events.append(:certificate_issued, %{}, ca_id: ca_id)
      {:ok, event3} = Events.append(:certificate_issued, %{}, ca_id: ca_id)

      assert event2.sequence > event1.sequence
      assert event3.sequence > event2.sequence
    end

    test "stores correlation_id when provided", %{ca_id: ca_id} do
      {:ok, event} =
        Events.append(:certificate_issued, %{},
          ca_id: ca_id,
          correlation_id: "req-123"
        )

      assert event.correlation_id == "req-123"
    end

    test "requires ca_id", %{ca_id: _ca_id} do
      # Should raise ArgumentError when ca_id is missing
      assert_raise ArgumentError, fn ->
        Events.append(:certificate_issued, %{})
      end
    end
  end

  describe "Events.query_by_ca/2" do
    test "queries events for a CA", %{ca_id: ca_id} do
      # Append multiple events
      Events.append(:ca_initialized, %{}, ca_id: ca_id)
      Events.append(:certificate_issued, %{serial: 1}, ca_id: ca_id)
      Events.append(:certificate_issued, %{serial: 2}, ca_id: ca_id)

      {:ok, events} = Events.query_by_ca(ca_id)

      assert length(events) >= 3
      assert Enum.all?(events, &(&1.ca_id == ca_id))
    end

    test "returns events in sequence order", %{ca_id: ca_id} do
      Events.append(:certificate_issued, %{order: 1}, ca_id: ca_id)
      Events.append(:certificate_issued, %{order: 2}, ca_id: ca_id)
      Events.append(:certificate_issued, %{order: 3}, ca_id: ca_id)

      {:ok, events} = Events.query_by_ca(ca_id)

      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences)
    end

    test "limits results when limit is specified", %{ca_id: ca_id} do
      for i <- 1..10 do
        Events.append(:certificate_issued, %{num: i}, ca_id: ca_id)
      end

      {:ok, events} = Events.query_by_ca(ca_id, limit: 5)

      assert length(events) <= 5
    end

    test "returns empty list for unknown CA" do
      {:ok, events} = Events.query_by_ca("ca:nonexistent")
      assert events == []
    end
  end

  describe "Events.query_by_type/2" do
    test "queries events by type", %{ca_id: ca_id} do
      Events.append(:certificate_issued, %{}, ca_id: ca_id)
      Events.append(:certificate_revoked, %{}, ca_id: ca_id)
      Events.append(:certificate_issued, %{}, ca_id: ca_id)

      {:ok, issued} = Events.query_by_type(:certificate_issued)

      assert length(issued) >= 2
      assert Enum.all?(issued, &(&1.event_type == :certificate_issued))
    end

    test "returns events ordered by timestamp", %{ca_id: ca_id} do
      Events.append(:certificate_issued, %{}, ca_id: ca_id)
      Process.sleep(10)
      Events.append(:certificate_issued, %{}, ca_id: ca_id)
      Process.sleep(10)
      Events.append(:certificate_issued, %{}, ca_id: ca_id)

      {:ok, events} = Events.query_by_type(:certificate_issued)

      timestamps = Enum.map(events, & &1.timestamp)

      # Check timestamps are in order (allowing for equal timestamps)
      assert Enum.chunk_every(timestamps, 2, 1, :discard)
             |> Enum.all?(fn [t1, t2] -> DateTime.compare(t1, t2) in [:lt, :eq] end)
    end
  end

  describe "Events.query_by_serial/1" do
    test "queries events by certificate serial", %{ca_id: ca_id} do
      serial = :erlang.unique_integer([:positive])

      Events.append(:certificate_issued, %{serial: serial}, ca_id: ca_id)
      Events.append(:certificate_validated, %{serial: serial}, ca_id: ca_id)
      Events.append(:certificate_revoked, %{serial: serial}, ca_id: ca_id)

      {:ok, events} = Events.query_by_serial(serial)

      assert length(events) == 3
      assert Enum.all?(events, &(&1.metadata.serial == serial))
    end

    test "returns empty list for unknown serial" do
      {:ok, events} = Events.query_by_serial(999_999_999)
      assert events == []
    end
  end

  describe "Events.get_certificate_state/1" do
    test "builds certificate state from events", %{ca_id: ca_id} do
      serial = :erlang.unique_integer([:positive])
      now = DateTime.utc_now()
      later = DateTime.add(now, 365, :day)

      # Issue certificate
      Events.append(
        :certificate_issued,
        %{
          serial: serial,
          subject: "/CN=test.com",
          not_before: now,
          not_after: later,
          certificate_der: <<1, 2, 3>>
        },
        ca_id: ca_id
      )

      {:ok, state} = Events.get_certificate_state(serial)

      assert state.status == :active
      assert state.serial == serial
      assert state.subject == "/CN=test.com"
      assert state.certificate_der == <<1, 2, 3>>
    end

    test "detects revoked status", %{ca_id: ca_id} do
      serial = :erlang.unique_integer([:positive])
      now = DateTime.utc_now()

      # Issue then revoke
      Events.append(
        :certificate_issued,
        %{
          serial: serial,
          subject: "/CN=revoked.com",
          not_before: now,
          not_after: DateTime.add(now, 365, :day)
        },
        ca_id: ca_id
      )

      Events.append(
        :certificate_revoked,
        %{
          serial: serial,
          reason: :keyCompromise,
          revocation_date: DateTime.utc_now()
        },
        ca_id: ca_id
      )

      {:ok, state} = Events.get_certificate_state(serial)

      assert state.status == :revoked
      assert state.revocation_reason == :keyCompromise
      assert state.revoked_at != nil
    end

    test "detects expired certificate", %{ca_id: ca_id} do
      serial = :erlang.unique_integer([:positive])
      past = DateTime.add(DateTime.utc_now(), -365, :day)

      # Issue certificate that already expired
      Events.append(
        :certificate_issued,
        %{
          serial: serial,
          subject: "/CN=expired.com",
          not_before: DateTime.add(past, -365, :day),
          not_after: past
        },
        ca_id: ca_id
      )

      {:ok, state} = Events.get_certificate_state(serial)

      assert state.status == :expired
    end

    test "returns unknown for nonexistent certificate" do
      {:ok, state} = Events.get_certificate_state(999_999_999)
      assert state.status == :unknown
    end
  end

  describe "Events.get_revocations/2" do
    test "returns all revocations for a CA", %{ca_id: ca_id} do
      # Issue and revoke multiple certificates
      for i <- 1..3 do
        serial = i * 1000

        Events.append(
          :certificate_issued,
          %{serial: serial, subject: "/CN=test#{i}.com"},
          ca_id: ca_id
        )

        Events.append(
          :certificate_revoked,
          %{
            serial: serial,
            reason: :keyCompromise,
            revocation_date: DateTime.utc_now()
          },
          ca_id: ca_id
        )
      end

      {:ok, revocations} = Events.get_revocations(ca_id)

      assert length(revocations) >= 3
      assert Enum.all?(revocations, &(&1.reason == :keyCompromise))
    end

    test "filters revocations by timestamp", %{ca_id: ca_id} do
      past = DateTime.add(DateTime.utc_now(), -1, :hour)
      now = DateTime.utc_now()

      # Old revocation
      Events.append(
        :certificate_revoked,
        %{serial: 1, reason: :superseded, revocation_date: past},
        ca_id: ca_id,
        timestamp: past
      )

      # Recent revocation
      Events.append(
        :certificate_revoked,
        %{serial: 2, reason: :keyCompromise, revocation_date: now},
        ca_id: ca_id
      )

      # Get only recent revocations
      since = DateTime.add(now, -30, :minute)
      {:ok, recent} = Events.get_revocations(ca_id, since: since)

      # Should only include the recent one
      assert Enum.any?(recent, &(&1.serial == 2))
    end
  end

  describe "Events.get_active_certificates/2" do
    test "returns only active certificates", %{ca_id: ca_id} do
      now = DateTime.utc_now()

      # Active certificate
      Events.append(
        :certificate_issued,
        %{
          serial: 1,
          subject: "/CN=active.com",
          not_before: now,
          not_after: DateTime.add(now, 365, :day)
        },
        ca_id: ca_id
      )

      # Revoked certificate
      Events.append(
        :certificate_issued,
        %{
          serial: 2,
          subject: "/CN=revoked.com",
          not_before: now,
          not_after: DateTime.add(now, 365, :day)
        },
        ca_id: ca_id
      )

      Events.append(
        :certificate_revoked,
        %{serial: 2, reason: :keyCompromise, revocation_date: now},
        ca_id: ca_id
      )

      # Expired certificate
      Events.append(
        :certificate_issued,
        %{
          serial: 3,
          subject: "/CN=expired.com",
          not_before: DateTime.add(now, -730, :day),
          not_after: DateTime.add(now, -365, :day)
        },
        ca_id: ca_id
      )

      {:ok, active} = Events.get_active_certificates(ca_id)

      active_serials = Enum.map(active, & &1.serial)
      assert 1 in active_serials
      assert 2 not in active_serials
      assert 3 not in active_serials
    end
  end

  describe "Events.get_expiring_certificates/2" do
    test "returns certificates expiring within specified days", %{ca_id: ca_id} do
      now = DateTime.utc_now()

      # Expires in 5 days
      Events.append(
        :certificate_issued,
        %{
          serial: 1,
          subject: "/CN=soon.com",
          not_before: now,
          not_after: DateTime.add(now, 5, :day)
        },
        ca_id: ca_id
      )

      # Expires in 50 days
      Events.append(
        :certificate_issued,
        %{
          serial: 2,
          subject: "/CN=later.com",
          not_before: now,
          not_after: DateTime.add(now, 50, :day)
        },
        ca_id: ca_id
      )

      # Get expiring in next 30 days
      {:ok, expiring} = Events.get_expiring_certificates(ca_id, 30)

      expiring_serials = Enum.map(expiring, & &1.serial)
      assert 1 in expiring_serials
      assert 2 not in expiring_serials
    end

    test "includes days_remaining in results", %{ca_id: ca_id} do
      now = DateTime.utc_now()

      Events.append(
        :certificate_issued,
        %{
          serial: 1,
          subject: "/CN=test.com",
          not_before: now,
          not_after: DateTime.add(now, 10, :day)
        },
        ca_id: ca_id
      )

      {:ok, expiring} = Events.get_expiring_certificates(ca_id, 30)

      cert = Enum.find(expiring, &(&1.serial == 1))
      assert cert != nil
      assert cert.days_remaining >= 9
      assert cert.days_remaining <= 11
    end

    test "sorts by expiration date", %{ca_id: ca_id} do
      now = DateTime.utc_now()

      # Create certificates expiring at different times
      for days <- [5, 15, 10, 20] do
        Events.append(
          :certificate_issued,
          %{
            serial: days,
            subject: "/CN=test#{days}.com",
            not_before: now,
            not_after: DateTime.add(now, days, :day)
          },
          ca_id: ca_id
        )
      end

      {:ok, expiring} = Events.get_expiring_certificates(ca_id, 30)

      # Should be sorted by not_after
      expiry_dates = Enum.map(expiring, & &1.not_after)

      assert expiry_dates ==
               Enum.sort(expiry_dates, fn d1, d2 ->
                 DateTime.compare(d1, d2) in [:lt, :eq]
               end)
    end
  end
end
