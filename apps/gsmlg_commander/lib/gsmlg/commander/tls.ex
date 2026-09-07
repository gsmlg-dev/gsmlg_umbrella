defmodule GSMLG.Commander.TLS do
  @moduledoc """
  Fail-closed Commander client TLS configuration and certificate rotation watcher.

  The watcher only invokes the configured connection restart callback. Browser
  capability processes and their work are not children of the connection subtree.
  """

  use GenServer

  @tls_versions [:"tlsv1.3", :"tlsv1.2"]

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def transport_opts(url, tls_config) do
    tls = normalize(tls_config)
    uri = URI.parse(url || "")

    cond do
      tls[:enabled] == true ->
        mtls_transport_opts(uri, tls)

      uri.scheme == "wss" and is_binary(uri.host) and uri.host != "" ->
        {:ok, [ssl: server_verification_options(uri, tls)]}

      uri.scheme == "wss" ->
        {:error, :invalid_commander_url}

      true ->
        {:ok, []}
    end
  end

  @doc "Returns the redacted TLS state advertised by a live Commander heartbeat."
  @spec connection_summary(String.t(), keyword() | map(), DateTime.t()) :: map()
  def connection_summary(url, tls_config, now \\ DateTime.utc_now()) do
    tls = normalize(tls_config)
    uri = URI.parse(url || "")

    cond do
      tls[:enabled] == true ->
        mtls_connection_summary(uri, tls, now)

      uri.scheme == "wss" and is_binary(uri.host) and uri.host != "" ->
        %{"status" => "server_verified"}

      uri.scheme == "ws" and is_binary(uri.host) and uri.host != "" ->
        %{"status" => "plaintext"}

      true ->
        %{"status" => "invalid"}
    end
  rescue
    _exception -> %{"status" => "invalid"}
  end

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    tls = opts |> Keyword.fetch!(:tls) |> normalize()

    with {:ok, _transport_opts} <- transport_opts(url, tls),
         {:ok, fingerprint} <- credential_fingerprint(tls) do
      state = %{
        url: url,
        tls: tls,
        fingerprint: fingerprint,
        pending_fingerprint: nil,
        reload_interval_ms:
          Keyword.get(opts, :reload_interval_ms, tls[:reload_interval_ms] || 60_000),
        restart_fun:
          Keyword.get(opts, :restart_fun, &GSMLG.Commander.ConnectionSupervisor.restart/0)
      }

      {:ok, schedule_check(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:check_credentials, state) do
    case credential_fingerprint(state.tls) do
      {:ok, fingerprint} when fingerprint == state.fingerprint ->
        {:noreply, schedule_check(%{state | pending_fingerprint: nil})}

      {:ok, fingerprint} when fingerprint != state.pending_fingerprint ->
        # Credential sets are commonly replaced as several files. Require one
        # stable polling interval before restarting so a valid intermediate
        # cert/key/CA combination cannot trigger an extra reconnect.
        {:noreply, schedule_check(%{state | pending_fingerprint: fingerprint})}

      {:ok, fingerprint} ->
        case transport_opts(state.url, state.tls) do
          {:ok, _transport_opts} ->
            case restart_connection(state.restart_fun) do
              :ok ->
                {:noreply,
                 schedule_check(%{
                   state
                   | fingerprint: fingerprint,
                     pending_fingerprint: nil
                 })}

              {:error, reason} ->
                log_rotation_failure(reason)
                {:noreply, schedule_check(state)}
            end

          {:error, reason} ->
            log_rotation_failure(reason)
            {:noreply, schedule_check(state)}
        end

      {:error, reason} ->
        log_rotation_failure(reason)
        {:noreply, schedule_check(%{state | pending_fingerprint: nil})}
    end
  end

  defp mtls_transport_opts(%URI{scheme: "wss", host: host} = uri, tls)
       when is_binary(host) and host != "" do
    with {:ok, cert_der} <- read_certificate(tls[:client_cert_file]),
         :ok <- validate_certificate_time(cert_der),
         {:ok, private_key} <- read_private_key(tls[:client_key_file]),
         :ok <- validate_key_pair(cert_der, private_key),
         {:ok, ca_option} <- ca_option(tls[:ca_cert_file]) do
      options =
        uri
        |> server_verification_options(tls)
        |> Keyword.merge(
          certfile: String.to_charlist(tls[:client_cert_file]),
          keyfile: String.to_charlist(tls[:client_key_file])
        )
        |> Keyword.delete(:cacerts)
        |> Keyword.put(elem(ca_option, 0), elem(ca_option, 1))

      {:ok, [ssl: options]}
    end
  end

  defp mtls_transport_opts(%URI{scheme: scheme}, _tls) when scheme != "wss",
    do: {:error, :mtls_requires_wss}

  defp mtls_transport_opts(_uri, _tls), do: {:error, :invalid_commander_url}

  defp mtls_connection_summary(%URI{scheme: "wss", host: host}, tls, %DateTime{} = now)
       when is_binary(host) and host != "" do
    with {:ok, cert_der} <- read_certificate(tls[:client_cert_file]),
         {:ok, {not_before, not_after}} <- certificate_validity(cert_der),
         {:ok, private_key} <- read_private_key(tls[:client_key_file]),
         :ok <- validate_key_pair(cert_der, private_key),
         {:ok, _ca_option} <- ca_option(tls[:ca_cert_file]) do
      now = DateTime.to_unix(now)

      status =
        cond do
          now < not_before -> "not_yet_valid"
          now > not_after -> "expired"
          true -> "verified"
        end

      %{
        "status" => status,
        "certificate_expires_at" => not_after |> DateTime.from_unix!() |> DateTime.to_iso8601()
      }
    else
      _invalid -> %{"status" => "invalid"}
    end
  end

  defp mtls_connection_summary(_uri, _tls, _now), do: %{"status" => "invalid"}

  defp server_verification_options(%URI{host: host}, tls) do
    base = [
      verify: :verify_peer,
      versions: @tls_versions,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case tls[:ca_cert_file] do
      path when is_binary(path) and path != "" ->
        Keyword.put(base, :cacertfile, String.to_charlist(path))

      _none ->
        Keyword.put(base, :cacerts, :public_key.cacerts_get())
    end
  end

  defp read_certificate(path) do
    with {:ok, pem} <- read_file(path, :client_cert_file_unreadable),
         [{:Certificate, der, _encryption} | _rest] <-
           Enum.filter(:public_key.pem_decode(pem), &(elem(&1, 0) == :Certificate)) do
      {:ok, der}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_client_certificate}
    end
  rescue
    _exception -> {:error, :invalid_client_certificate}
  end

  defp read_private_key(path) do
    with {:ok, pem} <- read_file(path, :client_key_file_unreadable),
         entry when not is_nil(entry) <- find_private_key(:public_key.pem_decode(pem)) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_client_private_key}
    end
  rescue
    _exception -> {:error, :invalid_client_private_key}
  end

  defp find_private_key(entries) do
    Enum.find(entries, fn {type, _der, _encryption} ->
      type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
    end)
  end

  defp validate_key_pair(cert_der, private_key) do
    with {:ok, cert_public_key} <- certificate_public_key(cert_der),
         {:ok, private_public_key} <- private_public_key(private_key) do
      if cert_public_key == private_public_key,
        do: :ok,
        else: {:error, :client_certificate_key_mismatch}
    else
      {:error, _reason} -> {:error, :client_certificate_key_mismatch}
    end
  end

  defp certificate_public_key(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, tbs, _algorithm, _signature} ->
        case elem(tbs, 7) do
          {:OTPSubjectPublicKeyInfo, _algorithm, {:ECPoint, point}} ->
            {:ok, {:ec, point}}

          {:OTPSubjectPublicKeyInfo, _algorithm, {:RSAPublicKey, modulus, exponent}} ->
            {:ok, {:rsa, modulus, exponent}}

          _unsupported ->
            {:error, :unsupported_certificate_key}
        end

      _invalid ->
        {:error, :invalid_client_certificate}
    end
  rescue
    _exception -> {:error, :invalid_client_certificate}
  end

  defp validate_certificate_time(cert_der) do
    with {:ok, {not_before, not_after}} <- certificate_validity(cert_der) do
      now = DateTime.utc_now() |> DateTime.to_unix()

      cond do
        now < not_before -> {:error, :client_certificate_not_yet_valid}
        now > not_after -> {:error, :client_certificate_expired}
        true -> :ok
      end
    else
      _invalid -> {:error, :invalid_client_certificate}
    end
  rescue
    _exception -> {:error, :invalid_client_certificate}
  end

  defp certificate_validity(cert_der) do
    with {:OTPCertificate, tbs, _algorithm, _signature} <-
           :public_key.pkix_decode_cert(cert_der, :otp),
         {:Validity, not_before, not_after} <- elem(tbs, 5),
         {:ok, not_before} <- certificate_time(not_before),
         {:ok, not_after} <- certificate_time(not_after) do
      {:ok, {not_before, not_after}}
    else
      _invalid -> {:error, :invalid_client_certificate}
    end
  rescue
    _exception -> {:error, :invalid_client_certificate}
  end

  defp certificate_time({:utcTime, value}), do: parse_certificate_time(value, 2)
  defp certificate_time({:generalTime, value}), do: parse_certificate_time(value, 4)
  defp certificate_time(_invalid), do: {:error, :invalid_certificate_time}

  defp parse_certificate_time(value, year_digits) do
    value = to_string(value)

    with true <- String.ends_with?(value, "Z"),
         {year, rest} <- String.split_at(String.trim_trailing(value, "Z"), year_digits),
         {month, rest} <- String.split_at(rest, 2),
         {day, rest} <- String.split_at(rest, 2),
         {hour, rest} <- String.split_at(rest, 2),
         {minute, second} <- String.split_at(rest, 2),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         year <- normalize_year(year, year_digits),
         {:ok, datetime} <-
           DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second)) do
      {:ok, DateTime.to_unix(datetime)}
    else
      _invalid -> {:error, :invalid_certificate_time}
    end
  rescue
    _exception -> {:error, :invalid_certificate_time}
  end

  defp normalize_year(year, 2) when year < 50, do: year + 2000
  defp normalize_year(year, 2), do: year + 1900
  defp normalize_year(year, 4), do: year

  defp private_public_key({:ECPrivateKey, _version, _key, _parameters, point, _attributes})
       when is_binary(point),
       do: {:ok, {:ec, point}}

  defp private_public_key(
         {:RSAPrivateKey, _version, modulus, exponent, _rest1, _rest2, _rest3, _rest4, _rest5,
          _rest6, _rest7}
       ),
       do: {:ok, {:rsa, modulus, exponent}}

  defp private_public_key(_unsupported), do: {:error, :unsupported_private_key}

  defp ca_option(path) when is_binary(path) and path != "" do
    with {:ok, pem} <- read_file(path, :ca_cert_file_unreadable),
         entries when entries != [] <-
           Enum.filter(:public_key.pem_decode(pem), &(elem(&1, 0) == :Certificate)) do
      {:ok, {:cacertfile, String.to_charlist(path)}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_ca_certificate}
    end
  rescue
    _exception -> {:error, :invalid_ca_certificate}
  end

  defp ca_option(_path), do: {:ok, {:cacerts, :public_key.cacerts_get()}}

  defp read_file(path, error) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> {:error, {error, path}}
    end
  end

  defp read_file(path, error), do: {:error, {error, path}}

  defp credential_fingerprint(tls) do
    paths = [tls[:client_cert_file], tls[:client_key_file], tls[:ca_cert_file]]

    Enum.reduce_while(paths, {:ok, []}, fn
      nil, {:ok, hashes} ->
        {:cont, {:ok, [nil | hashes]}}

      "", {:ok, hashes} ->
        {:cont, {:ok, [nil | hashes]}}

      path, {:ok, hashes} ->
        case File.read(path) do
          {:ok, content} -> {:cont, {:ok, [:crypto.hash(:sha256, content) | hashes]}}
          {:error, _reason} -> {:halt, {:error, {:credential_file_unreadable, path}}}
        end
    end)
    |> case do
      {:ok, hashes} -> {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(hashes))}
      {:error, _reason} = error -> error
    end
  end

  defp schedule_check(state) do
    Process.send_after(self(), :check_credentials, state.reload_interval_ms)
    state
  end

  defp log_rotation_failure(reason) do
    code =
      case reason do
        value when is_atom(value) -> value
        {value, _path} when is_atom(value) -> value
        _other -> :tls_configuration_error
      end

    GSMLG.Telemetry.error("Commander TLS credential rotation rejected",
      metadata: %{error_code: code}
    )
  end

  defp restart_connection(restart_fun) do
    case restart_fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :connection_restart_failed}
    end
  rescue
    _exception -> {:error, :connection_restart_failed}
  catch
    _kind, _reason -> {:error, :connection_restart_failed}
  end

  defp normalize(config) when is_map(config), do: Map.to_list(config)
  defp normalize(config) when is_list(config), do: config
  defp normalize(_config), do: []
end
