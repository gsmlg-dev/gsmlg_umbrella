defmodule GSMLG.AdminWeb.PKIContext do
  @moduledoc """
  Context module for PKI operations in the admin interface.

  This module wraps the GSMLG.PKI library and provides:
  - Session-process integration for real-time updates
  - Business logic for CA and certificate management
  - CSR workflow management
  - CRL generation
  - Certificate analytics and search

  ## Usage

  ```elixir
  # List all CAs
  {:ok, cas} = PKIContext.list_cas()

  # Issue a certificate
  {:ok, cert} = PKIContext.issue_certificate(ca_id, csr_pem, opts)

  # Generate CRL
  {:ok, crl} = PKIContext.generate_crl(ca_id)
  ```
  """

  import Ecto.Query
  alias GSMLG.Repo
  alias GSMLG.PKI.{CA, Events, Certificate, CSR, CRL}
  alias GSMLG.Schema.CSRRequest
  alias GSMLG.AdminWeb.PKIKeyStore
  alias Phoenix.SessionProcess

  require Logger

  ## CA Management

  @doc """
  List all Certificate Authorities with their statistics.
  """
  def list_cas do
    with {:ok, events} <- Events.query_by_type(:ca_initialized) do
      cas =
        events
        |> Enum.map(fn event ->
          {:ok, stats} = CA.get_stats(event.metadata.ca_id)

          %{
            id: event.metadata.ca_id,
            subject: event.metadata.subject,
            key_type: event.metadata.key_type,
            key_size: event.metadata[:key_size],
            serial: event.metadata.serial,
            not_before: event.metadata.not_before,
            not_after: event.metadata.not_after,
            created_at: event.timestamp,
            stats: stats,
            has_private_key: PKIKeyStore.key_exists?(event.metadata.ca_id)
          }
        end)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:ok, cas}
    end
  end

  @doc """
  Get a specific CA by ID with full details.
  """
  def get_ca(ca_id) do
    with {:ok, events} <- Events.query_by_ca(ca_id),
         init_event when not is_nil(init_event) <-
           Enum.find(events, &(&1.event_type == :ca_initialized)) do
      {:ok, cert} = Certificate.from_der(init_event.metadata.certificate_der)

      # Load private key if available
      private_key =
        case PKIKeyStore.load_ca_private_key(ca_id) do
          {:ok, key} -> key
          {:error, _} -> nil
        end

      ca = %{
        id: ca_id,
        certificate: cert,
        subject: init_event.metadata.subject,
        private_key: private_key,
        key_type: init_event.metadata.key_type,
        not_before: init_event.metadata.not_before,
        not_after: init_event.metadata.not_after
      }

      {:ok, ca}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Initialize a new Certificate Authority.

  ## Options
  - `:key_type` - :rsa or :ec (default: :rsa)
  - `:key_size` - 2048, 3072, 4096 for RSA (default: 4096)
  - `:validity` - Days until expiration (default: 7300 = 20 years)
  - `:actor` - Email of user performing action
  """
  def initialize_ca(subject, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    Logger.info("[PKI] Initializing CA: #{subject}", actor: actor)

    with {:ok, ca} <- CA.initialize(subject, opts),
         :ok <- PKIKeyStore.store_ca_private_key(ca.id, ca.private_key) do
      Logger.info("[PKI] CA initialized successfully: #{ca.id}", actor: actor)
      {:ok, ca}
    else
      {:error, reason} = error ->
        Logger.error("[PKI] Failed to initialize CA: #{inspect(reason)}", actor: actor)
        error
    end
  end

  @doc """
  Get statistics for a specific CA.
  """
  def get_ca_stats(ca_id) do
    CA.get_stats(ca_id)
  end

  ## Certificate Management

  @doc """
  List certificates with optional filtering.

  ## Options
  - `:status` - :all, :active, :revoked, :expired (default: :all)
  - `:ca_id` - Filter by issuing CA
  - `:limit` - Maximum number of results
  - `:offset` - Pagination offset
  """
  def list_certificates(opts \\ []) do
    status_filter = Keyword.get(opts, :status, :all)
    ca_id_filter = Keyword.get(opts, :ca_id)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    with {:ok, events} <- Events.query_by_type(:certificate_issued, limit: limit, offset: offset) do
      certificates =
        events
        |> Enum.map(fn event ->
          {:ok, state} = Events.get_certificate_state(event.metadata.serial)
          enrich_certificate_state(state)
        end)
        |> maybe_filter_by_status(status_filter)
        |> maybe_filter_by_ca(ca_id_filter)
        |> Enum.sort_by(& &1.issued_at, {:desc, DateTime})

      {:ok, certificates}
    end
  end

  @doc """
  Get a specific certificate by serial number.
  """
  def get_certificate(serial) when is_integer(serial) do
    with {:ok, state} <- Events.get_certificate_state(serial) do
      {:ok, enrich_certificate_state(state)}
    end
  end

  @doc """
  Issue a new certificate from a CSR.

  ## Options
  - `:template` - :server, :client, :ca, :code_signing, :email
  - `:validity` - Days until expiration (default: 365)
  - `:subject_alt_names` - List of SANs
  - `:actor` - Email of user performing action
  """
  def issue_certificate(ca_id, csr_pem, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    template = Keyword.get(opts, :template, :server)

    Logger.info("[PKI] Issuing certificate for CA: #{ca_id}", actor: actor, template: template)

    with {:ok, ca} <- get_ca(ca_id),
         {:ok, _csr} <- CSR.from_pem(csr_pem),
         {:ok, cert} <- CA.issue_certificate(ca, csr_pem, opts) do
      {:ok, cert_state} = Events.get_certificate_state(Certificate.serial(cert))

      Logger.info("[PKI] Certificate issued: #{cert_state.serial}",
        actor: actor,
        ca_id: ca_id
      )

      {:ok, enrich_certificate_state(cert_state)}
    else
      {:error, reason} = error ->
        Logger.error("[PKI] Failed to issue certificate: #{inspect(reason)}", actor: actor)
        error
    end
  end

  @doc """
  Revoke a certificate.

  ## Options
  - `:reason` - Revocation reason (:unspecified, :key_compromise, etc.)
  - `:invalidity_date` - Optional date when cert became invalid
  - `:actor` - Email of user performing action
  """
  def revoke_certificate(ca_id, serial, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    reason = Keyword.get(opts, :reason, :unspecified)

    Logger.warning("[PKI] Revoking certificate: #{serial}",
      actor: actor,
      reason: reason
    )

    with {:ok, ca} <- get_ca(ca_id),
         :ok <- CA.revoke_certificate(ca, serial, opts) do
      Logger.info("[PKI] Certificate revoked: #{serial}", actor: actor)
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[PKI] Failed to revoke certificate: #{inspect(reason)}", actor: actor)
        error
    end
  end

  @doc """
  Get certificates expiring within the specified number of days.
  """
  def get_expiring_certificates(ca_id, days \\ 30) do
    CA.get_expiring_certificates(ca_id, days)
  end

  @doc """
  Renew a certificate (issue new certificate with same subject/SANs).
  """
  def renew_certificate(serial, opts \\ []) do
    with {:ok, cert_state} <- Events.get_certificate_state(serial),
         {:ok, cert} <- Certificate.from_der(cert_state.certificate_der),
         {:ok, ca} <- get_ca(cert_state.issuer_ca_id) do
      # Extract subject and SANs from original certificate
      {:ok, subject} = Certificate.subject(cert)

      # Create new CSR with same subject (in production, you'd need the original key)
      # For now, require a new CSR to be provided
      {:error, :renewal_requires_new_csr}
    end
  end

  ## CSR Workflow Management

  @doc """
  Create a new CSR request for approval workflow.
  """
  def create_csr_request(attrs, requested_by) do
    attrs = Map.put(attrs, :requested_by, requested_by)

    %CSRRequest{}
    |> CSRRequest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List CSR requests with optional filtering.
  """
  def list_csr_requests(opts \\ []) do
    status = Keyword.get(opts, :status)
    ca_id = Keyword.get(opts, :ca_id)

    query = from(c in CSRRequest, order_by: [desc: c.inserted_at])

    query =
      if status do
        from(c in query, where: c.status == ^status)
      else
        query
      end

    query =
      if ca_id do
        from(c in query, where: c.ca_id == ^ca_id)
      else
        query
      end

    {:ok, Repo.all(query)}
  end

  @doc """
  Get a specific CSR request.
  """
  def get_csr_request(id) do
    case Repo.get(CSRRequest, id) do
      nil -> {:error, :not_found}
      csr_request -> {:ok, csr_request}
    end
  end

  @doc """
  Approve a CSR request and issue the certificate.
  """
  def approve_csr_request(id, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, csr_request} <- get_csr_request(id),
         true <- csr_request.status == :pending,
         {:ok, cert_state} <-
           issue_certificate(
             csr_request.ca_id,
             csr_request.csr_pem,
             template: csr_request.template,
             validity: csr_request.validity_days,
             actor: actor
           ) do
      # Update CSR request status
      csr_request
      |> CSRRequest.changeset(%{
        status: :issued,
        certificate_serial: cert_state.serial
      })
      |> Repo.update()

      {:ok, cert_state}
    else
      false -> {:error, :not_pending}
      error -> error
    end
  end

  @doc """
  Reject a CSR request.
  """
  def reject_csr_request(id, notes, _opts \\ []) do
    with {:ok, csr_request} <- get_csr_request(id),
         true <- csr_request.status == :pending do
      csr_request
      |> CSRRequest.changeset(%{status: :rejected, notes: notes})
      |> Repo.update()
    else
      false -> {:error, :not_pending}
      error -> error
    end
  end

  ## CRL Management

  @doc """
  Generate a Certificate Revocation List for a CA.
  """
  def generate_crl(ca_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Logger.info("[PKI] Generating CRL for CA: #{ca_id}", actor: actor)

    with {:ok, ca} <- get_ca(ca_id),
         {:ok, crl} <- CA.generate_crl(ca, opts) do
      Logger.info("[PKI] CRL generated for CA: #{ca_id}", actor: actor)
      {:ok, crl}
    end
  end

  @doc """
  Get the latest CRL for a CA.
  """
  def get_latest_crl(ca_id) do
    with {:ok, events} <- Events.query_by_ca(ca_id) do
      crl_event =
        events
        |> Enum.filter(&(&1.event_type == :crl_generated))
        |> Enum.max_by(& &1.timestamp, DateTime, fn -> nil end)

      if crl_event do
        {:ok, crl_der} = Base.decode64(crl_event.metadata.crl_der)
        {:ok, crl} = :public_key.der_decode(:CertificateList, crl_der)
        {:ok, crl}
      else
        {:error, :no_crl_found}
      end
    end
  end

  ## Search and Analytics

  @doc """
  Search certificates by various criteria.

  ## Options
  - `:subject` - Search in subject field
  - `:san` - Search in subject alternative names
  - `:serial` - Search by serial number
  - `:fingerprint` - Search by fingerprint
  """
  def search_certificates(query, opts \\ []) do
    search_type = Keyword.get(opts, :type, :subject)

    with {:ok, all_certs} <- list_certificates() do
      results =
        case search_type do
          :subject ->
            Enum.filter(all_certs, fn cert ->
              String.contains?(
                String.downcase(cert.subject),
                String.downcase(query)
              )
            end)

          :san ->
            Enum.filter(all_certs, fn cert ->
              Enum.any?(cert.subject_alt_names || [], fn san ->
                String.contains?(String.downcase(san), String.downcase(query))
              end)
            end)

          :serial ->
            serial = String.to_integer(query)
            Enum.filter(all_certs, &(&1.serial == serial))

          :fingerprint ->
            Enum.filter(all_certs, fn cert ->
              String.contains?(
                String.downcase(cert.fingerprint || ""),
                String.downcase(String.replace(query, ":", ""))
              )
            end)

          _ ->
            []
        end

      {:ok, results}
    end
  end

  @doc """
  Get analytics data for all CAs.
  """
  def get_analytics do
    with {:ok, cas} <- list_cas() do
      total_active = Enum.sum(Enum.map(cas, & &1.stats.active_certificates))
      total_revoked = Enum.sum(Enum.map(cas, & &1.stats.revoked_certificates))
      total_expired = Enum.sum(Enum.map(cas, & &1.stats.expired_certificates))

      analytics = %{
        total_cas: length(cas),
        total_certificates: total_active + total_revoked + total_expired,
        active_certificates: total_active,
        revoked_certificates: total_revoked,
        expired_certificates: total_expired,
        cas: cas
      }

      {:ok, analytics}
    end
  end

  @doc """
  Get expiry statistics across all CAs.
  """
  def get_expiry_stats do
    with {:ok, cas} <- list_cas() do
      expiry_data =
        Enum.map(cas, fn ca ->
          {:ok, expiring_7} = get_expiring_certificates(ca.id, 7)
          {:ok, expiring_30} = get_expiring_certificates(ca.id, 30)
          {:ok, expiring_90} = get_expiring_certificates(ca.id, 90)

          %{
            ca_id: ca.id,
            ca_subject: ca.subject,
            expiring_7_days: length(expiring_7),
            expiring_30_days: length(expiring_30),
            expiring_90_days: length(expiring_90)
          }
        end)

      {:ok, expiry_data}
    end
  end

  ## Session Process Integration

  @doc """
  Register session process handlers for PKI operations.
  """
  def register_session_handlers(session_id) do
    handlers = [
      {"list_cas", &handle_list_cas/2},
      {"get_ca", &handle_get_ca/2},
      {"list_certificates", &handle_list_certificates/2},
      {"get_certificate", &handle_get_certificate/2},
      {"list_csr_requests", &handle_list_csr_requests/2},
      {"get_analytics", &handle_get_analytics/2},
      {"get_expiry_stats", &handle_get_expiry_stats/2}
    ]

    Enum.each(handlers, fn {name, handler} ->
      SessionProcess.register_handler(session_id, name, handler)
    end)
  end

  defp handle_list_cas(_state, _args) do
    {:ok, cas} = list_cas()
    {:ok, %{pki: %{cas: cas}}}
  end

  defp handle_get_ca(_state, %{"ca_id" => ca_id}) do
    case get_ca(ca_id) do
      {:ok, ca} -> {:ok, %{pki: %{current_ca: ca}}}
      error -> error
    end
  end

  defp handle_list_certificates(_state, args) do
    {:ok, certificates} =
      list_certificates(
        status: args["status"] || :all,
        ca_id: args["ca_id"]
      )

    {:ok, %{pki: %{certificates: certificates}}}
  end

  defp handle_get_certificate(_state, %{"serial" => serial}) do
    case get_certificate(serial) do
      {:ok, cert} -> {:ok, %{pki: %{current_certificate: cert}}}
      error -> error
    end
  end

  defp handle_list_csr_requests(_state, args) do
    {:ok, requests} =
      list_csr_requests(
        status: args["status"],
        ca_id: args["ca_id"]
      )

    {:ok, %{pki: %{csr_requests: requests}}}
  end

  defp handle_get_analytics(_state, _args) do
    {:ok, analytics} = get_analytics()
    {:ok, %{pki: %{analytics: analytics}}}
  end

  defp handle_get_expiry_stats(_state, _args) do
    {:ok, stats} = get_expiry_stats()
    {:ok, %{pki: %{expiry_stats: stats}}}
  end

  ## Private Helpers

  defp enrich_certificate_state(state) do
    now = DateTime.utc_now()

    status =
      cond do
        state.revoked_at -> :revoked
        DateTime.compare(now, state.not_after) == :gt -> :expired
        DateTime.compare(now, state.not_before) == :lt -> :not_yet_valid
        true -> :active
      end

    days_until_expiry = DateTime.diff(state.not_after, now, :day)

    Map.merge(state, %{
      status: status,
      days_until_expiry: days_until_expiry,
      issued_at: state.events |> List.first() |> Map.get(:timestamp)
    })
  end

  defp maybe_filter_by_status(certs, :all), do: certs

  defp maybe_filter_by_status(certs, status) do
    Enum.filter(certs, &(&1.status == status))
  end

  defp maybe_filter_by_ca(certs, nil), do: certs

  defp maybe_filter_by_ca(certs, ca_id) do
    Enum.filter(certs, &(&1.issuer_ca_id == ca_id))
  end
end
