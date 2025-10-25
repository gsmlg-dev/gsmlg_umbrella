defmodule GSMLG.PKI.Events do
  @moduledoc """
  Event sourcing interface for PKI operations.

  This module provides functions to append and query immutable events
  representing all PKI operations. Events are stored in CouchDB and provide
  a complete audit trail.

  ## Event Types

  - `:ca_initialized` - A new CA was created
  - `:certificate_issued` - A certificate was issued
  - `:certificate_revoked` - A certificate was revoked
  - `:certificate_renewed` - A certificate was renewed
  - `:crl_generated` - A CRL was generated
  - `:certificate_validated` - A chain validation was performed

  ## Examples

      # Append a certificate issuance event
      GSMLG.PKI.Events.append(:certificate_issued, %{
        ca_id: "ca:root",
        serial: 12345,
        subject: "/CN=example.com",
        certificate_der: cert_der,
        actor: "admin@example.com"
      })

      # Query all events for a CA
      {:ok, events} = GSMLG.PKI.Events.query_by_ca("ca:root")

      # Get all revocation events
      {:ok, revocations} = GSMLG.PKI.Events.query_by_type(:certificate_revoked)

      # Build certificate state from events
      {:ok, state} = GSMLG.PKI.Events.get_certificate_state(12345)
  """

  alias GSMLG.PKI.Store.CouchDB

  @type event_type ::
          :ca_initialized
          | :certificate_issued
          | :certificate_revoked
          | :certificate_renewed
          | :crl_generated
          | :certificate_validated

  @type event :: %{
          required(:id) => String.t(),
          required(:type) => :pki_event,
          required(:event_type) => event_type(),
          required(:timestamp) => DateTime.t(),
          required(:sequence) => non_neg_integer(),
          required(:ca_id) => String.t(),
          required(:metadata) => map(),
          optional(:actor) => String.t(),
          optional(:correlation_id) => String.t()
        }

  @doc """
  Append a new event to the event store.

  ## Parameters

  - `event_type` - The type of event (atom)
  - `metadata` - Map containing event-specific data
  - `opts` - Keyword list of options:
    - `:ca_id` - CA identifier (required)
    - `:actor` - Who performed the action (optional)
    - `:correlation_id` - Request tracking ID (optional)
    - `:timestamp` - Event timestamp (defaults to now)

  ## Examples

      GSMLG.PKI.Events.append(:certificate_issued, %{
        serial: 12345,
        subject: "/CN=example.com",
        certificate_der: <<...>>
      }, ca_id: "ca:root", actor: "admin@example.com")
  """
  @spec append(event_type(), map(), keyword()) ::
          {:ok, event()} | {:error, term()}
  def append(event_type, metadata, opts \\ []) do
    ca_id = Keyword.fetch!(opts, :ca_id)
    actor = Keyword.get(opts, :actor)
    correlation_id = Keyword.get(opts, :correlation_id)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())

    event = %{
      id: generate_event_id(),
      type: :pki_event,
      event_type: event_type,
      timestamp: timestamp,
      sequence: get_next_sequence(ca_id),
      ca_id: ca_id,
      metadata: metadata,
      actor: actor,
      correlation_id: correlation_id
    }

    # Log event via telemetry
    GSMLG.Telemetry.emit(
      [:gsmlg, :pki, :event, :appended],
      %{sequence: event.sequence},
      %{
        event_type: event_type,
        ca_id: ca_id,
        actor: actor
      }
    )

    with {:ok, _doc} <- CouchDB.store_event(event) do
      {:ok, event}
    end
  end

  @doc """
  Query events by CA identifier.

  Returns all events for the specified CA, ordered by sequence number.

  ## Parameters

  - `ca_id` - The CA identifier
  - `opts` - Keyword list of options:
    - `:limit` - Maximum number of events to return
    - `:start_sequence` - Start from this sequence number
    - `:end_sequence` - End at this sequence number

  ## Examples

      {:ok, events} = GSMLG.PKI.Events.query_by_ca("ca:root")
      {:ok, recent} = GSMLG.PKI.Events.query_by_ca("ca:root", limit: 10)
  """
  @spec query_by_ca(String.t(), keyword()) ::
          {:ok, [event()]} | {:error, term()}
  def query_by_ca(ca_id, opts \\ []) do
    CouchDB.query_events_by_ca(ca_id, opts)
  end

  @doc """
  Query events by event type.

  Returns all events of the specified type, ordered by timestamp.

  ## Parameters

  - `event_type` - The event type atom
  - `opts` - Keyword list of options:
    - `:limit` - Maximum number of events to return
    - `:start_time` - Start from this timestamp
    - `:end_time` - End at this timestamp

  ## Examples

      {:ok, revocations} = GSMLG.PKI.Events.query_by_type(:certificate_revoked)
  """
  @spec query_by_type(event_type(), keyword()) ::
          {:ok, [event()]} | {:error, term()}
  def query_by_type(event_type, opts \\ []) do
    CouchDB.query_events_by_type(event_type, opts)
  end

  @doc """
  Query events by certificate serial number.

  Returns all events related to a specific certificate.

  ## Parameters

  - `serial` - Certificate serial number

  ## Examples

      {:ok, events} = GSMLG.PKI.Events.query_by_serial(12345)
  """
  @spec query_by_serial(non_neg_integer()) ::
          {:ok, [event()]} | {:error, term()}
  def query_by_serial(serial) do
    CouchDB.query_events_by_serial(serial)
  end

  @doc """
  Get the current state of a certificate by replaying its events.

  Returns a map containing the certificate's current status, metadata,
  and history.

  ## Parameters

  - `serial` - Certificate serial number

  ## Returns

  A map with the following keys:
  - `:status` - `:active`, `:revoked`, `:expired`, or `:unknown`
  - `:serial` - Certificate serial number
  - `:subject` - Certificate subject DN
  - `:not_before` - Validity start date
  - `:not_after` - Validity end date
  - `:certificate_der` - DER-encoded certificate (if available)
  - `:revoked_at` - Revocation timestamp (if revoked)
  - `:revocation_reason` - Revocation reason (if revoked)
  - `:events` - List of all events for this certificate

  ## Examples

      {:ok, state} = GSMLG.PKI.Events.get_certificate_state(12345)
      #=> %{
      #     status: :active,
      #     serial: 12345,
      #     subject: "/CN=example.com",
      #     not_before: ~U[2025-01-01 00:00:00Z],
      #     not_after: ~U[2026-01-01 00:00:00Z],
      #     ...
      #   }
  """
  @spec get_certificate_state(non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def get_certificate_state(serial) do
    with {:ok, events} <- query_by_serial(serial) do
      state = replay_certificate_events(events)
      {:ok, state}
    end
  end

  @doc """
  Get all revoked certificates for a CA.

  Returns a list of revocation entries suitable for CRL generation.

  ## Parameters

  - `ca_id` - The CA identifier
  - `opts` - Keyword list of options:
    - `:since` - Only include revocations after this timestamp

  ## Returns

  List of maps containing:
  - `:serial` - Certificate serial number
  - `:revocation_date` - When the certificate was revoked
  - `:reason` - Revocation reason code

  ## Examples

      {:ok, revocations} = GSMLG.PKI.Events.get_revocations("ca:root")
  """
  @spec get_revocations(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def get_revocations(ca_id, opts \\ []) do
    since = Keyword.get(opts, :since)

    with {:ok, events} <- query_by_ca(ca_id) do
      revocations =
        events
        |> Enum.filter(&(&1.event_type == :certificate_revoked))
        |> Enum.filter(fn event ->
          is_nil(since) or DateTime.compare(event.timestamp, since) == :gt
        end)
        |> Enum.map(fn event ->
          %{
            serial: event.metadata.serial,
            revocation_date: event.metadata.revocation_date,
            reason: event.metadata.reason
          }
        end)

      {:ok, revocations}
    end
  end

  @doc """
  Get active (non-revoked, non-expired) certificates for a CA.

  ## Parameters

  - `ca_id` - The CA identifier
  - `opts` - Keyword list of options:
    - `:at_time` - Check status at this timestamp (defaults to now)

  ## Examples

      {:ok, active_certs} = GSMLG.PKI.Events.get_active_certificates("ca:root")
  """
  @spec get_active_certificates(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def get_active_certificates(ca_id, opts \\ []) do
    at_time = Keyword.get(opts, :at_time, DateTime.utc_now())

    with {:ok, events} <- query_by_ca(ca_id) do
      # Build certificate states by serial number
      cert_states =
        events
        |> Enum.group_by(fn event ->
          event.metadata[:serial]
        end)
        |> Enum.filter(fn {serial, _events} -> not is_nil(serial) end)
        |> Enum.map(fn {_serial, cert_events} ->
          replay_certificate_events(cert_events, at_time)
        end)
        |> Enum.filter(fn state ->
          state.status == :active
        end)

      {:ok, cert_states}
    end
  end

  @doc """
  Get certificates expiring within the specified number of days.

  ## Parameters

  - `ca_id` - The CA identifier
  - `days` - Number of days to look ahead (default: 30)

  ## Examples

      {:ok, expiring} = GSMLG.PKI.Events.get_expiring_certificates("ca:root", 30)
  """
  @spec get_expiring_certificates(String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_expiring_certificates(ca_id, days \\ 30) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, days, :day)

    with {:ok, active} <- get_active_certificates(ca_id) do
      expiring =
        active
        |> Enum.filter(fn cert ->
          DateTime.compare(cert.not_after, threshold) == :lt
        end)
        |> Enum.map(fn cert ->
          days_remaining = DateTime.diff(cert.not_after, now, :day)
          Map.put(cert, :days_remaining, days_remaining)
        end)
        |> Enum.sort_by(& &1.not_after, DateTime)

      {:ok, expiring}
    end
  end

  # Private Functions

  defp generate_event_id do
    "event:" <> GSMLG.PKI.Events.UUID.uuid4()
  end

  defp get_next_sequence(ca_id) do
    # Get the highest sequence number for this CA
    case query_by_ca(ca_id, limit: 1, descending: true) do
      {:ok, [last_event | _]} -> last_event.sequence + 1
      {:ok, []} -> 1
      {:error, _} -> 1
    end
  end

  defp replay_certificate_events(events, at_time \\ nil) do
    check_time = at_time || DateTime.utc_now()

    initial_state = %{
      status: :unknown,
      serial: nil,
      subject: nil,
      not_before: nil,
      not_after: nil,
      certificate_der: nil,
      events: []
    }

    final_state =
      Enum.reduce(events, initial_state, fn event, state ->
        state = Map.update!(state, :events, &(&1 ++ [event]))

        case event.event_type do
          :certificate_issued ->
            %{
              state
              | status: :active,
                serial: event.metadata.serial,
                subject: event.metadata.subject,
                not_before: parse_datetime(event.metadata.not_before),
                not_after: parse_datetime(event.metadata.not_after),
                certificate_der: event.metadata.certificate_der
            }

          :certificate_revoked ->
            %{
              state
              | status: :revoked,
                revoked_at: parse_datetime(event.metadata.revocation_date),
                revocation_reason: event.metadata.reason
            }

          :certificate_renewed ->
            # Mark as renewed, but state is determined by subsequent issuance event
            Map.put(state, :renewed_from, event.metadata.old_serial)

          _ ->
            state
        end
      end)

    # Check expiry status
    cond do
      final_state.status == :revoked ->
        final_state

      final_state.not_after && DateTime.compare(check_time, final_state.not_after) == :gt ->
        %{final_state | status: :expired}

      final_state.not_before && DateTime.compare(check_time, final_state.not_before) == :lt ->
        %{final_state | status: :not_yet_valid}

      true ->
        final_state
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(dt) when is_struct(dt, DateTime), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # UUID generation helper (simple implementation)
  defmodule UUID do
    @doc false
    def uuid4 do
      <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

      <<a::48, 4::4, b::12, 2::2, c::62>>
      |> Base.encode16(case: :lower)
      |> format_uuid()
    end

    defp format_uuid(<<
           a::binary-size(8),
           b::binary-size(4),
           c::binary-size(4),
           d::binary-size(4),
           e::binary-size(12)
         >>) do
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end
  end
end
