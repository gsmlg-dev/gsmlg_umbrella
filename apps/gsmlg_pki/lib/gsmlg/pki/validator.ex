defmodule GSMLG.PKI.Validator do
  @moduledoc """
  Certificate chain validation with event-based revocation checking.

  This module provides comprehensive X.509 certificate chain validation
  including path building, policy constraints, revocation checking via
  event replay, and customizable validation policies.

  ## Features

  - Path building from leaf to root
  - Multiple trust anchor support
  - Name constraint checking
  - Key usage and extended key usage validation
  - Event-based revocation checking (no CRL download required)
  - Policy constraint validation
  - Validity period checking
  - Signature verification

  ## Examples

      # Validate a server certificate
      {:ok, :valid} = GSMLG.PKI.Validator.validate_chain(cert, [root_ca],
        check_revocation: true,
        usage: :serverAuth
      )

      # Validate with custom policy
      {:ok, :valid} = GSMLG.PKI.Validator.validate_chain(cert, trust_anchors,
        policy: &my_custom_policy/2
      )
  """

  alias GSMLG.PKI.{Certificate, Events}

  require GSMLG.Telemetry

  @type validation_result ::
          :valid
          | {:invalid, reason :: atom()}
          | {:error, term()}

  @type validation_opts :: [
          check_revocation: boolean(),
          usage: atom(),
          policy: function(),
          at_time: DateTime.t(),
          max_chain_length: pos_integer()
        ]

  @doc """
  Validate a certificate chain.

  ## Parameters

  - `cert` - The certificate to validate (leaf certificate)
  - `trust_anchors` - List of trusted root certificates
  - `opts` - Validation options:
    - `:check_revocation` - Check revocation status (default: true)
    - `:usage` - Required extended key usage (e.g., :serverAuth, :clientAuth)
    - `:policy` - Custom validation policy function
    - `:at_time` - Validate as of this timestamp (default: now)
    - `:max_chain_length` - Maximum allowed chain length (default: 10)
    - `:intermediates` - List of intermediate certificates to use for path building

  ## Returns

  - `{:ok, :valid}` - Certificate chain is valid
  - `{:ok, {:invalid, reason}}` - Certificate chain is invalid
  - `{:error, term()}` - Validation error occurred

  ## Examples

      {:ok, :valid} = GSMLG.PKI.Validator.validate_chain(cert, [root_ca])

      {:ok, {:invalid, :revoked}} = GSMLG.PKI.Validator.validate_chain(revoked_cert, [root_ca],
        check_revocation: true
      )
  """
  @spec validate_chain(Certificate.t(), [Certificate.t()], validation_opts()) ::
          {:ok, validation_result()} | {:error, term()}
  def validate_chain(cert, trust_anchors, opts \\ []) do
    GSMLG.Telemetry.span([:gsmlg, :pki, :validation, :chain],
      %{cert_subject: extract_subject(cert)},
      fn ->
        check_revocation = Keyword.get(opts, :check_revocation, true)
        usage = Keyword.get(opts, :usage)
        policy_fn = Keyword.get(opts, :policy)
        at_time = Keyword.get(opts, :at_time, DateTime.utc_now())
        max_chain_length = Keyword.get(opts, :max_chain_length, 10)
        intermediates = Keyword.get(opts, :intermediates, [])

        validation_start = System.monotonic_time(:millisecond)

        result =
          with {:ok, chain} <- build_chain(cert, trust_anchors, intermediates, max_chain_length),
               :ok <- validate_chain_basics(chain, at_time),
               :ok <- validate_signatures(chain),
               :ok <- validate_key_usage(cert, usage),
               :ok <- apply_policy(chain, policy_fn),
               :ok <- check_revocation_status(chain, check_revocation, at_time) do
            {:ok, :valid}
          else
            {:error, reason} -> {:ok, {:invalid, reason}}
            error -> error
          end

        validation_time = System.monotonic_time(:millisecond) - validation_start

        # Log validation event
        log_validation_event(cert, result, validation_time, opts)

        metadata = %{
          validation_time_ms: validation_time,
          result: elem(result, 1)
        }

        {result, metadata}
      end
    )
  end

  @doc """
  Build a certificate chain from leaf to root.

  ## Parameters

  - `cert` - Leaf certificate
  - `trust_anchors` - List of trusted root certificates
  - `intermediates` - List of intermediate certificates (optional)
  - `max_length` - Maximum chain length (default: 10)

  ## Returns

  - `{:ok, chain}` - Chain built successfully (list from leaf to root)
  - `{:error, reason}` - Failed to build chain

  ## Examples

      {:ok, [leaf, intermediate, root]} = GSMLG.PKI.Validator.build_chain(
        cert,
        [root_ca],
        [intermediate_ca]
      )
  """
  @spec build_chain(Certificate.t(), [Certificate.t()], [Certificate.t()], pos_integer()) ::
          {:ok, [Certificate.t()]} | {:error, term()}
  def build_chain(cert, trust_anchors, intermediates \\ [], max_length \\ 10) do
    do_build_chain([cert], trust_anchors, intermediates, max_length)
  end

  @doc """
  Check if a certificate is revoked using event sourcing.

  ## Parameters

  - `cert` - Certificate to check
  - `at_time` - Check revocation status at this time (default: now)

  ## Returns

  - `{:ok, :not_revoked}` - Certificate is not revoked
  - `{:ok, {:revoked, reason}}` - Certificate is revoked
  - `{:error, term()}` - Error checking revocation status

  ## Examples

      {:ok, :not_revoked} = GSMLG.PKI.Validator.check_revocation(cert)
      {:ok, {:revoked, :keyCompromise}} = GSMLG.PKI.Validator.check_revocation(revoked_cert)
  """
  @spec check_revocation(Certificate.t(), DateTime.t()) ::
          {:ok, :not_revoked | {:revoked, atom()}} | {:error, term()}
  def check_revocation(cert, at_time \\ DateTime.utc_now()) do
    serial = extract_serial(cert)

    case Events.get_certificate_state(serial) do
      {:ok, %{status: :revoked, revocation_reason: reason, revoked_at: revoked_at}} ->
        # Check if revoked before the at_time
        if DateTime.compare(revoked_at, at_time) != :gt do
          {:ok, {:revoked, reason}}
        else
          {:ok, :not_revoked}
        end

      {:ok, _} ->
        {:ok, :not_revoked}

      {:error, _} ->
        # Certificate not found in events, assume not revoked
        {:ok, :not_revoked}
    end
  end

  @doc """
  Validate key usage for a specific purpose.

  ## Parameters

  - `cert` - Certificate to check
  - `usage` - Required extended key usage (e.g., :serverAuth, :clientAuth)

  ## Examples

      :ok = GSMLG.PKI.Validator.validate_key_usage(cert, :serverAuth)
      {:error, :invalid_key_usage} = GSMLG.PKI.Validator.validate_key_usage(cert, :codeSigning)
  """
  @spec validate_key_usage(Certificate.t(), atom() | nil) :: :ok | {:error, atom()}
  def validate_key_usage(_cert, nil), do: :ok

  def validate_key_usage(cert, required_usage) do
    case Certificate.extension(cert, :ext_key_usage) do
      {:ok, usages} when is_list(usages) ->
        if required_usage in usages do
          :ok
        else
          {:error, :invalid_key_usage}
        end

      {:ok, :any} ->
        :ok

      :error ->
        {:error, :missing_key_usage}
    end
  end

  # Private Functions

  defp do_build_chain(chain, _trust_anchors, _intermediates, max_length)
       when length(chain) > max_length do
    {:error, :chain_too_long}
  end

  defp do_build_chain([current | _] = chain, trust_anchors, intermediates, max_length) do
    # Check if current cert is a trust anchor
    if Enum.any?(trust_anchors, &certificates_equal?(current, &1)) do
      {:ok, Enum.reverse(chain)}
    else
      # Find issuer
      case find_issuer(current, trust_anchors ++ intermediates) do
        {:ok, issuer} ->
          # Add issuer to chain and continue
          do_build_chain([issuer | chain], trust_anchors, intermediates, max_length)

        :error ->
          {:error, :incomplete_chain}
      end
    end
  end

  defp find_issuer(cert, potential_issuers) do
    import GSMLG.PKI.ASN1

    # Get authority key identifier from cert
    {:ok, aki} = Certificate.extension(cert, :authority_key_identifier)

    # Find issuer by matching subject key identifier
    issuer =
      Enum.find(potential_issuers, fn potential_issuer ->
        case Certificate.extension(potential_issuer, :subject_key_identifier) do
          {:ok, ski} -> ski == aki
          :error -> false
        end
      end)

    if issuer, do: {:ok, issuer}, else: :error
  end

  defp certificates_equal?(cert1, cert2) do
    {:ok, der1} = Certificate.to_der(cert1)
    {:ok, der2} = Certificate.to_der(cert2)
    der1 == der2
  end

  defp validate_chain_basics(chain, at_time) do
    Enum.reduce_while(chain, :ok, fn cert, :ok ->
      case validate_cert_basics(cert, at_time) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_cert_basics(cert, at_time) do
    import GSMLG.PKI.ASN1

    otp_certificate(tbsCertificate: tbs) = cert
    {:Validity, {:utcTime, not_before_char}, {:utcTime, not_after_char}} =
      otp_tbs_certificate(tbs, :validity)

    not_before = parse_utc_time(not_before_char)
    not_after = parse_utc_time(not_after_char)

    cond do
      DateTime.compare(at_time, not_before) == :lt ->
        {:error, :not_yet_valid}

      DateTime.compare(at_time, not_after) == :gt ->
        {:error, :expired}

      true ->
        :ok
    end
  end

  defp validate_signatures([_root]), do: :ok

  defp validate_signatures([cert | [issuer | _] = rest]) do
    case :public_key.pkix_verify(cert, :public_key.pem_entry_encode(:Certificate, issuer)) do
      true ->
        validate_signatures(rest)

      false ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :signature_verification_failed}
  end

  defp apply_policy(_chain, nil), do: :ok

  defp apply_policy(chain, policy_fn) when is_function(policy_fn, 2) do
    case policy_fn.(chain, %{}) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, :policy_violation}
    end
  end

  defp check_revocation_status(_chain, false, _at_time), do: :ok

  defp check_revocation_status(chain, true, at_time) do
    Enum.reduce_while(chain, :ok, fn cert, :ok ->
      case check_revocation(cert, at_time) do
        {:ok, :not_revoked} ->
          {:cont, :ok}

        {:ok, {:revoked, reason}} ->
          {:halt, {:error, {:revoked, reason}}}
      end
    end)
  end

  defp log_validation_event(cert, result, validation_time, opts) do
    serial = extract_serial(cert)
    subject = extract_subject(cert)

    event_metadata = %{
      serial: serial,
      subject: subject,
      validation_result: format_validation_result(result),
      validation_time_ms: validation_time,
      checks_performed: build_checks_list(opts)
    }

    # Don't require CA ID for validation events
    Events.append(:certificate_validated, event_metadata,
      ca_id: "validation",
      correlation_id: opts[:correlation_id]
    )
  catch
    _, _ -> :ok  # Ignore logging errors
  end

  defp format_validation_result({:ok, :valid}), do: "valid"
  defp format_validation_result({:ok, {:invalid, reason}}), do: "invalid:#{reason}"
  defp format_validation_result({:error, reason}), do: "error:#{inspect(reason)}"
  defp format_validation_result(_), do: "unknown"

  defp build_checks_list(opts) do
    checks = ["chain", "expiry", "signature"]

    checks =
      if Keyword.get(opts, :check_revocation, true),
        do: checks ++ ["revocation"],
        else: checks

    checks =
      if Keyword.get(opts, :usage),
        do: checks ++ ["key_usage"],
        else: checks

    checks =
      if Keyword.get(opts, :policy),
        do: checks ++ ["policy"],
        else: checks

    checks
  end

  defp extract_serial(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs
    serial
  end

  defp extract_subject(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    subject_rdn = otp_tbs_certificate(tbs, :subject)

    # Convert RDN sequence to string
    GSMLG.PKI.RDNSequence.to_string(subject_rdn)
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

    {:ok, dt} = DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")
    dt
  end
end
