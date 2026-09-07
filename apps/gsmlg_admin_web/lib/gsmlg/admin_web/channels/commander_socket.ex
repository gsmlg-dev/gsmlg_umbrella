defmodule GSMLG.AdminWeb.CommanderSocket do
  use Phoenix.Socket

  channel("command_platform", GSMLG.AdminWeb.CommandPlatformChannel)
  channel("commander:*", GSMLG.AdminWeb.CommanderChannel)
  channel("terminal:*", GSMLG.AdminWeb.TerminalChannel)

  @impl true
  def connect(_params, socket, connect_info) do
    case credentials_from_headers(connect_info) do
      {:ok, params} -> connect_authenticated(params, socket, connect_info)
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect_authenticated(
         %{
           name: name,
           credential_id: credential_id,
           sign_at: sign_at,
           nonce: nonce,
           signature: signature
         },
         socket,
         connect_info
       ) do
    params = %{
      name: name,
      credential_id: credential_id,
      sign_at: sign_at,
      nonce: nonce,
      signature: signature
    }

    case authenticate(params) do
      :ok ->
        GSMLG.Telemetry.info("Commander socket authenticated",
          metadata: %{
            socket_type: "commander",
            commander_name: name,
            credential_id: credential_id,
            peer_address: peer_address(connect_info)
          }
        )

        {:ok,
         socket
         |> assign(:peer_data, Map.get(connect_info, :peer_data))
         |> assign(:name, name)
         |> assign(:commander_name, name)
         |> assign(:credential_id, credential_id)
         |> assign(:connection_id, make_ref())}

      {:error, reason} ->
        GSMLG.Telemetry.error("Commander socket signature verification failed",
          metadata: %{
            socket_type: "commander",
            commander_name_size: binary_size(name),
            credential_id_size: binary_size(credential_id),
            error_code: reason,
            security_event: "commander_authentication_failed"
          }
        )

        {:error, reason}
    end
  end

  @impl true
  def id(socket), do: "commander:#{socket.assigns.commander_name}"

  defp authenticate(params) do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])

    with {:ok, sign_at} <- parse_timestamp(params.sign_at),
         :ok <- validate_timestamp(sign_at, config),
         {:ok, key, expected_name} <- credential(config, params.credential_id),
         :ok <- validate_identity(params.name, expected_name),
         :ok <- verify_signature(params, sign_at, key),
         :ok <- claim_nonce(params.credential_id, params.nonce, config) do
      :ok
    end
  end

  defp parse_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid_timestamp}

  defp validate_timestamp(sign_at, config) do
    window = Keyword.get(config, :auth_timestamp_window_seconds, 60)

    if abs(System.system_time(:second) - sign_at) <= window,
      do: :ok,
      else: {:error, :expired_signature}
  end

  defp credential(config, credential_id) do
    credentials = Keyword.get(config, :platform_credentials, %{})

    case credential_entry(credentials, credential_id) do
      {:ok, credential} ->
        parse_credential(credential, credential_id)

      :error ->
        {:error, :unknown_credential}
    end
  end

  defp credential_entry(credentials, credential_id) when is_map(credentials) do
    Enum.find_value(credentials, :error, fn
      {key, credential} when is_binary(key) ->
        if key == credential_id, do: {:ok, credential}

      {key, credential} when is_atom(key) ->
        if Atom.to_string(key) == credential_id, do: {:ok, credential}

      {_key, _credential} ->
        false
    end)
  end

  defp credential_entry(_credentials, _credential_id), do: :error

  defp parse_credential(%{key: key, commander_name: name}, _credential_id)
       when is_binary(key) and byte_size(key) > 0 and is_binary(name) and byte_size(name) > 0,
       do: {:ok, key, name}

  defp parse_credential(%{"key" => key, "commander_name" => name}, _credential_id)
       when is_binary(key) and byte_size(key) > 0 and is_binary(name) and byte_size(name) > 0,
       do: {:ok, key, name}

  defp parse_credential(credentials, _credential_id) when is_list(credentials) do
    case {Keyword.fetch(credentials, :key), Keyword.fetch(credentials, :commander_name)} do
      {{:ok, key}, {:ok, name}}
      when is_binary(key) and byte_size(key) > 0 and is_binary(name) and byte_size(name) > 0 ->
        {:ok, key, name}

      _invalid ->
        {:error, :invalid_credential}
    end
  end

  defp parse_credential(key, credential_id) when is_binary(key) and byte_size(key) > 0,
    do: {:ok, key, credential_id}

  defp parse_credential(_credential, _credential_id), do: {:error, :invalid_credential}

  defp validate_identity(name, name), do: :ok
  defp validate_identity(_name, _expected), do: {:error, :credential_identity_mismatch}

  defp verify_signature(params, sign_at, key) do
    expected =
      params.credential_id
      |> signature_payload(params.name, sign_at, params.nonce)
      |> then(&:crypto.mac(:hmac, :sha256, key, &1))
      |> Base.encode16(case: :lower)

    supplied = if is_binary(params.signature), do: String.downcase(params.signature), else: ""

    if byte_size(supplied) == byte_size(expected) and
         Plug.Crypto.secure_compare(supplied, expected),
       do: :ok,
       else: {:error, :invalid_signature}
  end

  defp claim_nonce(credential_id, nonce, config)
       when is_binary(nonce) and byte_size(nonce) >= 16 and byte_size(nonce) <= 128 do
    ttl = Keyword.get(config, :auth_nonce_ttl_ms, :timer.minutes(2))
    replay_cache = Keyword.get(config, :replay_cache, GSMLG.CommandPlatform.ReplayCache)

    case GSMLG.CommandPlatform.ReplayCache.claim(
           replay_cache,
           {:commander_auth, credential_id, nonce},
           ttl
         ) do
      :ok -> :ok
      {:error, :already_claimed} -> {:error, :nonce_replayed}
      {:error, :capacity_reached} -> {:error, :auth_capacity_reached}
    end
  end

  defp claim_nonce(_credential_id, _nonce, _config), do: {:error, :invalid_nonce}

  defp signature_payload(credential_id, name, sign_at, nonce) do
    "v1\n#{credential_id}\n#{name}\n#{sign_at}\n#{nonce}"
  end

  defp peer_address(connect_info) do
    case Map.get(connect_info, :peer_data) do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _none -> nil
    end
  end

  defp binary_size(value) when is_binary(value), do: byte_size(value)
  defp binary_size(_value), do: 0

  defp credentials_from_headers(connect_info) do
    headers = Map.get(connect_info, :x_headers, [])

    values =
      Map.new(headers, fn {name, value} ->
        {String.downcase(name), value}
      end)

    with {:ok, name} <- Map.fetch(values, "x-commander-name"),
         {:ok, credential_id} <- Map.fetch(values, "x-commander-credential-id"),
         {:ok, sign_at} <- Map.fetch(values, "x-commander-sign-at"),
         {:ok, nonce} <- Map.fetch(values, "x-commander-nonce"),
         {:ok, signature} <- Map.fetch(values, "x-commander-signature") do
      {:ok,
       %{
         name: name,
         credential_id: credential_id,
         sign_at: sign_at,
         nonce: nonce,
         signature: signature
       }}
    else
      :error -> {:error, :missing_credentials}
    end
  rescue
    _exception -> {:error, :missing_credentials}
  end
end
