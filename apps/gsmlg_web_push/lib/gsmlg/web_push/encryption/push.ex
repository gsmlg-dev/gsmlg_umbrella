defmodule GSMLG.WebPush.Encryption.Push do
  @moduledoc """
  Module to send web push notifications with a payload through GCM
  """

  alias GSMLG.WebPush.Encryption.Vapid

  @fcm_url "https://fcm.googleapis.com/fcm/send"

  @fcm_project_based_url "https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send"

  def project_url(project_id) do
    String.replace(@fcm_project_based_url, "{PROJECT_ID}", project_id)
  end

  @doc """
  Sends a web push notification with a payload through GCM.

  ## Arguments

    * `message` is a binary payload. It can be JSON encoded
    * `subscription` is the subscription information received from the client.
       It should have the following form: `%{keys: %{auth: AUTH, p256dh: P256DH}, endpoint: ENDPOINT}`
    * `auth_token` [Optional] is the GCM api key matching the `gcm_sender_id` from the client `manifest.json`.
       It is not necessary for Mozilla endpoints.
    * `ttl` [Optional] is a non-negative integer Time To Live.
       It is the number of seconds that a message may be stored if the user is not immediately available.
       Mozilla Push Service only supports a maximum TTL of 5,184,000 seconds (about one month).

  ## Return value

  Returns `{:ok, %HTTP.Response{}}` or `{:error, reason}` from `HTTP.fetch/2`.
  """
  @spec send_web_push(
          message :: binary,
          subscription :: map,
          auth_token :: binary | nil,
          ttl :: integer
        ) ::
          {:ok, HTTP.Response.t()} | {:error, term()}
  def send_web_push(message, subscription, auth_token \\ nil, ttl \\ 0)

  def send_web_push(_message, _subscription, _auth_token, ttl)
      when not is_integer(ttl) or ttl < 0 do
    raise ArgumentError,
          "send_web_push expects a non-negative integer ttl"
  end

  def send_web_push(message, %{endpoint: endpoint} = subscription, auth_token, ttl) do
    payload = GSMLG.WebPush.Encryption.Encrypt.encrypt(message, subscription)

    headers =
      Vapid.get_headers(make_audience(endpoint), "aesgcm")
      |> Map.merge(%{
        "TTL" => to_string(ttl),
        "Content-Encoding" => "aesgcm",
        "Encryption" => "salt=#{ub64(payload.salt)}"
      })

    headers =
      headers
      |> Map.put("Crypto-Key", "dh=#{ub64(payload.server_public_key)};" <> headers["Crypto-Key"])

    {endpoint, headers} = make_request_params(endpoint, headers, auth_token)

    options = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2"],
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    endpoint
    |> fetch(method: :post, body: payload.ciphertext, headers: headers, ssl: options[:ssl])
    |> await_http_response()
  end

  def send_web_push(_message, _subscription, _auth_token, _ttl) do
    raise ArgumentError,
          "send_web_push expects a subscription endpoint with an endpoint parameter"
  end

  defp make_request_params(endpoint, headers, auth_token) do
    cond do
      fcm_url?(endpoint) and not is_nil(auth_token) ->
        {endpoint, headers |> Map.merge(fcm_gcm_authorization(auth_token))}

      true ->
        {endpoint, headers}
    end
  end

  defp make_audience(endpoint) do
    parsed = URI.parse(endpoint)
    parsed.scheme <> "://" <> parsed.host
  end

  defp fcm_url?(url), do: String.starts_with?(url, @fcm_url)
  defp fcm_gcm_authorization(auth_token), do: %{"Authorization" => "key=#{auth_token}"}

  defp ub64(value) do
    Base.url_encode64(value, padding: false)
  end

  defp http_client() do
    Application.get_env(:gsmlg_web_push, :http_client, HTTP)
  end

  defp fetch(endpoint, options) do
    client = http_client()

    case ensure_http_client_started(client) do
      :ok -> client.fetch(endpoint, options)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_http_client_started(HTTP) do
    case Application.ensure_all_started(:http_fetch) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_http_client_started(_client), do: :ok

  defp await_http_response(%HTTP.Promise{} = promise) do
    case HTTP.Promise.await(promise) do
      %HTTP.Response{} = response -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_http_response({:ok, %HTTP.Response{}} = result), do: result
  defp await_http_response({:error, _reason} = error), do: error
end
