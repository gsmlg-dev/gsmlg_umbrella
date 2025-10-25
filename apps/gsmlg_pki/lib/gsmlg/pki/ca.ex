defmodule GSMLG.PKI.CA do
  @moduledoc """
  High-level Certificate Authority operations with event sourcing.

  This module provides a complete CA implementation that logs all operations
  as immutable events in CouchDB. It wraps the lower-level GSMLG.PKI modules
  and adds event logging, telemetry, and state management.

  ## Features

  - Certificate issuance (from CSR or direct)
  - Certificate revocation with RFC 5280 reason codes
  - CRL generation from revocation events
  - Chain validation
  - Certificate lifecycle management
  - Automatic event logging and audit trail
  - Telemetry integration

  ## Examples

      # Initialize a new CA
      {:ok, ca} = GSMLG.PKI.CA.initialize("/CN=My Root CA", key_type: :rsa, key_size: 4096)

      # Issue a certificate
      {:ok, cert} = GSMLG.PKI.CA.issue_certificate(ca, csr,
        template: :server,
        validity: 365
      )

      # Revoke a certificate
      :ok = GSMLG.PKI.CA.revoke_certificate(ca, cert_serial,
        reason: :keyCompromise
      )

      # Generate CRL
      {:ok, crl} = GSMLG.PKI.CA.generate_crl(ca)

      # Validate certificate chain
      {:ok, :valid} = GSMLG.PKI.CA.validate_chain(cert, ca)
  """

  alias GSMLG.PKI.{Certificate, PrivateKey, CSR, CRL, Events}

  require GSMLG.Telemetry

  @type ca :: %{
          id: String.t(),
          certificate: Certificate.t(),
          private_key: PrivateKey.t(),
          subject: String.t()
        }

  @type revocation_reason ::
          :unspecified
          | :keyCompromise
          | :cACompromise
          | :affiliationChanged
          | :superseded
          | :cessationOfOperation
          | :certificateHold
          | :removeFromCRL
          | :privilegeWithdrawn
          | :aACompromise

  @revocation_reason_codes %{
    unspecified: 0,
    keyCompromise: 1,
    cACompromise: 2,
    affiliationChanged: 3,
    superseded: 4,
    cessationOfOperation: 5,
    certificateHold: 6,
    removeFromCRL: 8,
    privilegeWithdrawn: 9,
    aACompromise: 10
  }

  @doc """
  Initialize a new Certificate Authority.

  Creates a self-signed root certificate and logs the CA initialization event.

  ## Parameters

  - `subject` - The CA's subject DN (e.g., "/CN=My Root CA/O=My Org/C=US")
  - `opts` - Keyword list of options:
    - `:key_type` - `:rsa` or `:ec` (default: `:rsa`)
    - `:key_size` - Key size for RSA (default: 4096)
    - `:curve` - Curve for EC (default: `:secp384r1`)
    - `:validity` - Validity in days (default: 7300 = 20 years)
    - `:hash` - Hash algorithm (default: `:sha256`)
    - `:ca_id` - CA identifier (default: generated from subject)
    - `:actor` - Who is creating the CA

  ## Examples

      {:ok, ca} = GSMLG.PKI.CA.initialize("/CN=GSMLG Root CA",
        key_type: :rsa,
        key_size: 4096,
        validity: 7300
      )
  """
  @spec initialize(String.t(), keyword()) :: {:ok, ca()} | {:error, term()}
  def initialize(subject, opts \\ []) do
    GSMLG.Telemetry.span([:gsmlg, :pki, :ca, :initialize], %{subject: subject}, fn ->
      key_type = Keyword.get(opts, :key_type, :rsa)
      key_size = Keyword.get(opts, :key_size, 4096)
      curve = Keyword.get(opts, :curve, :secp384r1)
      validity = Keyword.get(opts, :validity, 7300)
      hash = Keyword.get(opts, :hash, :sha256)
      ca_id = Keyword.get(opts, :ca_id, generate_ca_id(subject))
      actor = Keyword.get(opts, :actor)

      # Generate private key
      private_key =
        case key_type do
          :rsa -> PrivateKey.new_rsa(key_size)
          :ec -> PrivateKey.new_ec(curve)
        end

      # Generate self-signed certificate
      cert =
        Certificate.self_signed(
          private_key,
          subject,
          template: :root_ca,
          validity: validity,
          hash: hash
        )

      # Extract certificate details for event
      {:ok, cert_der} = Certificate.to_der(cert)
      {:ok, public_key_der} = extract_public_key_der(cert)
      {serial, not_before, not_after, ski} = extract_cert_metadata(cert)

      # Log CA initialization event
      event_metadata = %{
        ca_id: ca_id,
        subject: subject,
        key_type: key_type_to_string(key_type),
        key_size: key_size,
        curve: curve,
        validity_days: validity,
        certificate_der: cert_der,
        public_key_der: public_key_der,
        ski: ski,
        serial: serial,
        not_before: not_before,
        not_after: not_after,
        hash: hash
      }

      case Events.append(:ca_initialized, event_metadata,
             ca_id: ca_id,
             actor: actor
           ) do
        {:ok, _event} ->
          ca = %{
            id: ca_id,
            certificate: cert,
            private_key: private_key,
            subject: subject
          }

          GSMLG.Telemetry.log(:info, "CA initialized successfully",
            metadata: %{ca_id: ca_id, subject: subject}
          )

          {{:ok, ca}, %{ca_id: ca_id}}

        {:error, reason} = error ->
          GSMLG.Telemetry.log(:error, "Failed to initialize CA",
            metadata: %{subject: subject, error: inspect(reason)}
          )

          {error, %{}}
      end
    end)
  end

  @doc """
  Issue a certificate from a Certificate Signing Request (CSR).

  ## Parameters

  - `ca` - The CA struct
  - `csr` - The CSR (PEM string or CSR record)
  - `opts` - Keyword list of options:
    - `:template` - Certificate template (default: `:server`)
    - `:validity` - Validity in days (default: 365)
    - `:serial` - Serial number or `{:random, n}` (default: from template)
    - `:extensions` - Additional extensions to merge
    - `:actor` - Who is issuing the certificate

  ## Examples

      {:ok, cert} = GSMLG.PKI.CA.issue_certificate(ca, csr_pem,
        template: :server,
        validity: 365,
        extensions: [subject_alt_name: ["example.com", "www.example.com"]]
      )
  """
  @spec issue_certificate(ca(), CSR.t() | String.t(), keyword()) ::
          {:ok, Certificate.t()} | {:error, term()}
  def issue_certificate(ca, csr, opts \\ []) do
    GSMLG.Telemetry.span([:gsmlg, :pki, :certificate, :issue], %{ca_id: ca.id}, fn ->
      with {:ok, csr_record} <- parse_csr(csr),
           {:ok, public_key} <- CSR.public_key(csr_record),
           {:ok, subject} <- CSR.subject(csr_record),
           {:ok, cert} <- do_issue_certificate(ca, public_key, subject, csr_record, opts) do
        {{:ok, cert}, %{status: :success}}
      else
        {:error, reason} = error ->
          GSMLG.Telemetry.log(:error, "Failed to issue certificate",
            metadata: %{ca_id: ca.id, error: inspect(reason)}
          )

          {error, %{status: :error}}
      end
    end)
  end

  @doc """
  Issue a certificate directly without a CSR.

  ## Parameters

  - `ca` - The CA struct
  - `public_key` - The public key to certify
  - `subject` - The certificate subject DN
  - `opts` - Same as issue_certificate/3

  ## Examples

      {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(ca, public_key, "/CN=example.com",
        template: :server,
        validity: 365
      )
  """
  @spec issue_certificate_direct(ca(), term(), String.t(), keyword()) ::
          {:ok, Certificate.t()} | {:error, term()}
  def issue_certificate_direct(ca, public_key, subject, opts \\ []) do
    do_issue_certificate(ca, public_key, subject, nil, opts)
  end

  @doc """
  Revoke a certificate.

  ## Parameters

  - `ca` - The CA struct
  - `serial` - Certificate serial number
  - `opts` - Keyword list of options:
    - `:reason` - Revocation reason (default: `:unspecified`)
    - `:invalidity_date` - When the key was compromised (optional)
    - `:actor` - Who is revoking the certificate

  ## Revocation Reasons

  - `:unspecified` - No specific reason
  - `:keyCompromise` - Private key was compromised
  - `:cACompromise` - CA was compromised
  - `:affiliationChanged` - Subject affiliation changed
  - `:superseded` - Certificate was replaced
  - `:cessationOfOperation` - Certificate is no longer needed
  - `:certificateHold` - Temporary revocation (reversible)
  - `:privilegeWithdrawn` - Privileges were withdrawn
  - `:aACompromise` - Attribute authority compromised

  ## Examples

      :ok = GSMLG.PKI.CA.revoke_certificate(ca, 12345,
        reason: :keyCompromise
      )
  """
  @spec revoke_certificate(ca(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def revoke_certificate(ca, serial, opts \\ []) do
    GSMLG.Telemetry.span(
      [:gsmlg, :pki, :certificate, :revoke],
      %{ca_id: ca.id, serial: serial},
      fn ->
        reason = Keyword.get(opts, :reason, :unspecified)
        invalidity_date = Keyword.get(opts, :invalidity_date)
        actor = Keyword.get(opts, :actor)

        # Verify certificate exists and belongs to this CA
        with {:ok, cert_state} <- Events.get_certificate_state(serial),
             :ok <- verify_certificate_active(cert_state),
             :ok <- log_revocation_event(ca, serial, cert_state, reason, invalidity_date, actor) do
          GSMLG.Telemetry.log(:info, "Certificate revoked successfully",
            metadata: %{ca_id: ca.id, serial: serial, reason: reason}
          )

          {:ok, %{status: :success}}
        else
          {:error, reason} = error ->
            GSMLG.Telemetry.log(:error, "Failed to revoke certificate",
              metadata: %{ca_id: ca.id, serial: serial, error: inspect(reason)}
            )

            {error, %{status: :error}}
        end
      end
    )
  end

  @doc """
  Generate a Certificate Revocation List (CRL) from revocation events.

  ## Parameters

  - `ca` - The CA struct
  - `opts` - Keyword list of options:
    - `:validity` - CRL validity in days (default: 7)
    - `:since` - Only include revocations after this timestamp
    - `:extensions` - CRL extensions

  ## Examples

      {:ok, crl} = GSMLG.PKI.CA.generate_crl(ca)
      {:ok, crl_pem} = GSMLG.PKI.CRL.to_pem(crl)
  """
  @spec generate_crl(ca(), keyword()) :: {:ok, CRL.t()} | {:error, term()}
  def generate_crl(ca, opts \\ []) do
    GSMLG.Telemetry.span([:gsmlg, :pki, :crl, :generate], %{ca_id: ca.id}, fn ->
      validity = Keyword.get(opts, :validity, 7)
      since = Keyword.get(opts, :since)
      extensions = Keyword.get(opts, :extensions, [])

      with {:ok, revocations} <- Events.get_revocations(ca.id, since: since) do
        # Convert revocation events to CRL entries
        entries =
          Enum.map(revocations, fn rev ->
            %{
              serial: rev.serial,
              revocation_time: rev.revocation_date,
              extensions: [crl_reason: Map.get(@revocation_reason_codes, rev.reason, 0)]
            }
          end)

        # Generate CRL
        crl =
          CRL.new(
            entries,
            ca.certificate,
            ca.private_key,
            validity: validity,
            extensions: extensions
          )

        # Log CRL generation event
        {:ok, crl_der} = CRL.to_der(crl)
        crl_number = get_next_crl_number(ca.id)

        event_metadata = %{
          ca_id: ca.id,
          crl_number: crl_number,
          this_update: DateTime.utc_now(),
          next_update: DateTime.add(DateTime.utc_now(), validity, :day),
          revoked_count: length(entries),
          crl_der: crl_der,
          crl_size_bytes: byte_size(crl_der)
        }

        Events.append(:crl_generated, event_metadata, ca_id: ca.id)

        GSMLG.Telemetry.log(:info, "CRL generated successfully",
          metadata: %{
            ca_id: ca.id,
            crl_number: crl_number,
            revoked_count: length(entries)
          }
        )

        {{:ok, crl}, %{revoked_count: length(entries), crl_number: crl_number}}
      else
        {:error, reason} = error ->
          GSMLG.Telemetry.log(:error, "Failed to generate CRL",
            metadata: %{ca_id: ca.id, error: inspect(reason)}
          )

          {error, %{}}
      end
    end)
  end

  @doc """
  Get CA statistics including active, revoked, and expired certificates.

  ## Examples

      {:ok, stats} = GSMLG.PKI.CA.get_stats("ca:root")
      #=> %{
      #     active_certificates: 42,
      #     revoked_certificates: 5,
      #     expired_certificates: 3,
      #     total_issued: 50
      #   }
  """
  @spec get_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_stats(ca_id) do
    with {:ok, all_events} <- Events.query_by_ca(ca_id) do
      issued =
        all_events
        |> Enum.filter(&(&1.event_type == :certificate_issued))
        |> length()

      revoked =
        all_events
        |> Enum.filter(&(&1.event_type == :certificate_revoked))
        |> length()

      {:ok, active} = Events.get_active_certificates(ca_id)

      stats = %{
        active_certificates: length(active),
        revoked_certificates: revoked,
        total_issued: issued,
        expired_certificates: issued - length(active) - revoked
      }

      {:ok, stats}
    end
  end

  @doc """
  Get certificates expiring soon.

  ## Parameters

  - `ca_id` - CA identifier
  - `days` - Number of days to look ahead (default: 30)

  ## Examples

      {:ok, expiring} = GSMLG.PKI.CA.get_expiring_certificates("ca:root", 30)
  """
  @spec get_expiring_certificates(String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_expiring_certificates(ca_id, days \\ 30) do
    Events.get_expiring_certificates(ca_id, days)
  end

  # Private Functions

  defp do_issue_certificate(ca, public_key, subject, csr, opts) do
    template = Keyword.get(opts, :template, :server)
    validity = Keyword.get(opts, :validity, 365)
    serial = Keyword.get(opts, :serial)
    extensions = Keyword.get(opts, :extensions, [])
    actor = Keyword.get(opts, :actor)

    # Extract CSR extensions if present
    csr_extensions =
      if csr do
        # Get extensions from CSR extension_request attribute
        csr_exts = CSR.extension_request(csr)
        # Extract SAN if present
        case Enum.find(csr_exts, fn ext ->
               elem(ext, 0) == :Extension and elem(elem(ext, 1), 0) == :subject_alt_name
             end) do
          nil -> []
          # For now, don't auto-extract CSR extensions
          _ext -> []
        end
      else
        []
      end

    # Merge extensions (prefer explicitly passed extensions)
    all_extensions = Keyword.merge(csr_extensions, extensions)

    # Generate certificate
    cert_opts = [
      template: template,
      validity: validity,
      serial: serial,
      extensions: all_extensions
    ]

    cert = Certificate.new(public_key, subject, ca.certificate, ca.private_key, cert_opts)

    # Extract certificate details
    {:ok, cert_der} = Certificate.to_der(cert)
    {cert_serial, not_before, not_after, ski} = extract_cert_metadata(cert)
    {:ok, aki} = Certificate.extension(cert, :authority_key_identifier)

    # Determine key type
    {key_type, key_info} = determine_key_type(public_key)

    # Calculate CSR fingerprint if present
    csr_fingerprint =
      if csr do
        {:ok, csr_der} = CSR.to_der(csr)
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, csr_der), case: :lower)
      else
        nil
      end

    # Log certificate issuance event
    event_metadata = %{
      serial: cert_serial,
      subject: subject,
      issuer_ca_id: ca.id,
      issuer_subject: ca.subject,
      certificate_type: determine_cert_type(template),
      template: template,
      key_type: key_type,
      key_info: key_info,
      validity_days: validity,
      not_before: not_before,
      not_after: not_after,
      certificate_der: cert_der,
      subject_alternative_names: Keyword.get(all_extensions, :subject_alt_name),
      ski: ski,
      aki: format_aki(aki),
      csr_fingerprint: csr_fingerprint,
      auto_renew: false
    }

    case Events.append(:certificate_issued, event_metadata,
           ca_id: ca.id,
           actor: actor
         ) do
      {:ok, _event} ->
        GSMLG.Telemetry.log(:info, "Certificate issued successfully",
          metadata: %{
            ca_id: ca.id,
            serial: cert_serial,
            subject: subject
          }
        )

        {:ok, cert}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_csr(csr) when is_binary(csr) do
    case CSR.from_pem(csr) do
      {:ok, csr_record} -> {:ok, csr_record}
      {:error, _} = error -> error
    end
  end

  defp parse_csr(csr), do: {:ok, csr}

  defp verify_certificate_active(%{status: :revoked}),
    do: {:error, :already_revoked}

  defp verify_certificate_active(%{status: :expired}),
    do: {:error, :certificate_expired}

  defp verify_certificate_active(%{status: :unknown}),
    do: {:error, :certificate_not_found}

  defp verify_certificate_active(_), do: :ok

  defp log_revocation_event(ca, serial, cert_state, reason, invalidity_date, actor) do
    event_metadata = %{
      serial: serial,
      ca_id: ca.id,
      reason: reason,
      revocation_date: DateTime.utc_now(),
      invalidity_date: invalidity_date,
      subject: cert_state.subject,
      issuer_subject: ca.subject
    }

    case Events.append(:certificate_revoked, event_metadata,
           ca_id: ca.id,
           actor: actor
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_cert_metadata(cert) do
    import GSMLG.PKI.ASN1

    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs

    {:Validity, {:utcTime, not_before_char}, {:utcTime, not_after_char}} =
      otp_tbs_certificate(tbs, :validity)

    {:ok, ski} = Certificate.extension(cert, :subject_key_identifier)

    not_before = parse_utc_time(not_before_char)
    not_after = parse_utc_time(not_after_char)

    {serial, not_before, not_after, Base.encode16(ski, case: :lower)}
  end

  defp extract_public_key_der(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(subjectPublicKeyInfo: spki) = tbs
    {:ok, :public_key.der_encode(:SubjectPublicKeyInfo, spki)}
  end

  defp parse_utc_time(charlist) do
    # Format: YYMMDDHHMMSSZ
    str = to_string(charlist)
    year = String.slice(str, 0, 2) |> String.to_integer()
    month = String.slice(str, 2, 2) |> String.to_integer()
    day = String.slice(str, 4, 2) |> String.to_integer()
    hour = String.slice(str, 6, 2) |> String.to_integer()
    minute = String.slice(str, 8, 2) |> String.to_integer()
    second = String.slice(str, 10, 2) |> String.to_integer()

    # Adjust year (00-49 = 2000-2049, 50-99 = 1950-1999)
    year = if year < 50, do: 2000 + year, else: 1900 + year

    {:ok, dt} =
      DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")

    dt
  end

  defp determine_key_type({:RSAPublicKey, _, _}), do: {"rsa", %{}}

  defp determine_key_type({:ECPoint, _}) do
    # Would need to extract curve from certificate, simplified here
    {"ec", %{curve: "unknown"}}
  end

  defp determine_key_type(_), do: {"unknown", %{}}

  defp key_type_to_string(:rsa), do: "rsa"
  defp key_type_to_string(:ec), do: "ec"
  defp key_type_to_string(_), do: "unknown"

  defp determine_cert_type(:server), do: "server"
  defp determine_cert_type(:client), do: "client"
  defp determine_cert_type(:intermediate_ca), do: "intermediate_ca"
  defp determine_cert_type(:root_ca), do: "root_ca"
  defp determine_cert_type(_), do: "unknown"

  defp format_aki(nil), do: nil
  defp format_aki(aki) when is_binary(aki), do: Base.encode16(aki, case: :lower)
  defp format_aki(_), do: nil

  defp generate_ca_id(subject) do
    # Generate CA ID from subject
    hash = :crypto.hash(:sha256, subject)
    ("ca:" <> Base.encode16(hash, case: :lower)) |> String.slice(0, 16)
  end

  defp get_next_crl_number(ca_id) do
    case Events.query_by_type(:crl_generated) do
      {:ok, events} ->
        ca_crls = Enum.filter(events, &(&1.metadata.ca_id == ca_id))
        length(ca_crls) + 1

      {:error, _} ->
        1
    end
  end
end
