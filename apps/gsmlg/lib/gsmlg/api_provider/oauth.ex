defmodule GSMLG.ApiProvider.OAuth do
  @moduledoc """
  OAuth2 helpers for API providers with `auth_type: "oauth"`.

  Supports building authorization URLs, exchanging authorization codes for
  tokens, and transparently refreshing expired access tokens.

  ## Supported providers

  - `"github"` — GitHub OAuth Apps
  - `"openai"` — OpenAI OAuth

  ## Token storage

  OAuth state is stored in the provider's `credentials` map:

      %{
        client_id:        "...",
        client_secret:    "...",
        access_token:     "...",
        refresh_token:    "...",
        token_expires_at: unix_timestamp   # 0 means no expiry (e.g. GitHub)
      }
  """

  require Logger
  alias GSMLG.ApiProvider
  alias GSMLG.ApiProviders

  @endpoints %{
    "github" => %{
      authorize: "https://github.com/login/oauth/authorize",
      token: "https://github.com/login/oauth/access_token"
    },
    "openai" => %{
      authorize: "https://auth.openai.com/authorize",
      token: "https://auth.openai.com/oauth/token"
    }
  }

  @doc """
  Builds the OAuth2 authorization URL for a provider.

  `redirect_uri` and `scope` should be passed in `opts`.
  """
  def authorize_url(provider, name, opts \\ []) do
    case Map.fetch(@endpoints, provider) do
      {:ok, %{authorize: base_url}} ->
        case ApiProviders.get_api_provider_by(provider, name) do
          %ApiProvider{credentials: %{client_id: client_id}} ->
            params =
              URI.encode_query(
                %{
                  client_id: client_id,
                  redirect_uri: opts[:redirect_uri],
                  scope: opts[:scope],
                  state: opts[:state]
                }
                |> Enum.reject(fn {_k, v} -> is_nil(v) end)
                |> Map.new()
              )

            {:ok, "#{base_url}?#{params}"}

          nil ->
            {:error, :provider_not_found}
        end

      :error ->
        {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.

  Persists the resulting tokens to the database and updates the in-memory
  Vault via PubSub.
  """
  def exchange_code(provider, name, code, redirect_uri \\ nil) do
    with {:ok, %{token: token_url}} <- Map.fetch(@endpoints, provider),
         %ApiProvider{} = api_provider <- ApiProviders.get_api_provider_by(provider, name),
         %{client_id: client_id, client_secret: client_secret} <- api_provider.credentials,
         {:ok, tokens} <- request_token(token_url, client_id, client_secret, code, redirect_uri) do
      new_credentials =
        api_provider.credentials
        |> Map.merge(%{
          access_token: tokens["access_token"],
          refresh_token: tokens["refresh_token"],
          token_expires_at: expiry_timestamp(tokens["expires_in"])
        })

      ApiProviders.update_oauth_tokens(api_provider, new_credentials)
    else
      :error -> {:error, {:unsupported_provider, provider}}
      nil -> {:error, :provider_not_found}
      error -> error
    end
  end

  @doc """
  Ensures the access token is valid, refreshing it if expired.

  Returns `{:ok, token_string}` or `{:error, reason}`.
  Called by `GSMLG.ApiProvider.Vault.get_token/2`.
  """
  def ensure_valid_token(%ApiProvider{credentials: creds} = api_provider) do
    expires_at = creds[:token_expires_at] || 0

    if expires_at > 0 and :os.system_time(:second) >= expires_at do
      case refresh_token(api_provider) do
        {:ok, api_provider} -> {:ok, api_provider.credentials[:access_token]}
        error -> error
      end
    else
      token = creds[:access_token]
      if token, do: {:ok, token}, else: :error
    end
  end

  @doc """
  Refreshes the access token using the stored refresh token.

  Persists updated credentials and returns `{:ok, updated_api_provider}`.
  """
  def refresh_token(%ApiProvider{provider: provider, credentials: creds} = api_provider) do
    with {:ok, %{token: token_url}} <- Map.fetch(@endpoints, provider),
         refresh <- Map.get(creds, :refresh_token),
         true <- is_binary(refresh) and refresh != "",
         {:ok, tokens} <-
           request_refresh(
             token_url,
             creds[:client_id],
             creds[:client_secret],
             refresh
           ) do
      new_credentials =
        creds
        |> Map.merge(%{
          access_token: tokens["access_token"],
          refresh_token: tokens["refresh_token"] || refresh,
          token_expires_at: expiry_timestamp(tokens["expires_in"])
        })

      case ApiProviders.update_oauth_tokens(api_provider, new_credentials) do
        {:ok, updated} -> {:ok, updated}
        error -> error
      end
    else
      :error -> {:error, {:unsupported_provider, provider}}
      false -> {:error, :no_refresh_token}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp request_token(url, client_id, client_secret, code, redirect_uri) do
    body =
      %{
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: redirect_uri
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    post_json(url, body)
  end

  defp request_refresh(url, client_id, client_secret, refresh_token) do
    body = %{
      grant_type: "refresh_token",
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token
    }

    post_json(url, body)
  end

  defp post_json(url, body) do
    headers = [{"accept", "application/json"}, {"content-type", "application/json"}]

    case Finch.build(:post, url, headers, Jason.encode!(body))
         |> Finch.request(GSMLG.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.error("[ApiProvider.OAuth] Token request failed #{status}: #{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("[ApiProvider.OAuth] Token request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp expiry_timestamp(nil), do: 0
  defp expiry_timestamp(0), do: 0

  defp expiry_timestamp(expires_in) when is_integer(expires_in) do
    :os.system_time(:second) + expires_in
  end

  defp expiry_timestamp(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {seconds, _} -> expiry_timestamp(seconds)
      :error -> 0
    end
  end
end
