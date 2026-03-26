defmodule GSMLG.AWS.Client do
  require Logger

  @doc """
  Creates an AWS client for the named credential set.

  Credentials are loaded from Application env key `:aws_credentials`, which is
  populated by `GSMLG.ApiProvider.Vault` when it unseals. The map is keyed by
  provider name (default: `"default"`):

      Application.get_env(:gsmlg_aws, :aws_credentials)
      #=> %{"default" => %{access_key_id: "AKIA...", secret_access_key: "...", region: "..."}}
  """
  def get_client(name \\ "default") do
    credentials = Application.get_env(:gsmlg_aws, :aws_credentials, %{})

    case Map.get(credentials, name) do
      %{access_key_id: access_key_id, secret_access_key: secret_access_key, region: region} ->
        case validate_credentials(access_key_id, secret_access_key, region) do
          :ok ->
            AWS.Client.create(access_key_id, secret_access_key, region)
            |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, []})
            |> Map.put(:proto_version, "2.0")
            |> Map.put(:content_type, "application/x-amz-json-1.0")

          {:error, reason} ->
            Logger.error("Invalid AWS credentials for provider #{inspect(name)}: #{reason}")
            raise ArgumentError, "Cannot create AWS client: #{reason}"
        end

      _ ->
        Logger.error(
          "AWS provider #{inspect(name)} not configured in :gsmlg_aws :aws_credentials"
        )

        raise ArgumentError, "Cannot create AWS client: provider #{inspect(name)} not configured"
    end
  end

  @doc """
  Validates AWS credentials and returns appropriate error messages.
  """
  def validate_credentials(access_key_id, secret_access_key, region) do
    cond do
      is_nil(access_key_id) or String.trim(access_key_id) == "" ->
        {:error, "AWS_ACCESS_KEY_ID not set or empty"}

      is_nil(secret_access_key) or String.trim(secret_access_key) == "" ->
        {:error, "AWS_SECRET_ACCESS_KEY not set or empty"}

      is_nil(region) or String.trim(region) == "" ->
        {:error, "AWS_REGION not set or empty"}

      not is_valid_access_key?(access_key_id) ->
        {:error, "Invalid AWS_ACCESS_KEY_ID format"}

      not is_valid_secret_key?(secret_access_key) ->
        {:error, "Invalid AWS_SECRET_ACCESS_KEY format"}

      not is_valid_region?(region) ->
        {:error, "Invalid AWS_REGION format"}

      true ->
        :ok
    end
  end

  @doc """
  Validates AWS Access Key ID format (starts with 'AKIA' and is 20 characters).
  """
  def is_valid_access_key?(access_key_id) do
    is_binary(access_key_id) and
      String.length(String.trim(access_key_id)) == 20 and
      String.starts_with?(String.trim(access_key_id), "AKIA")
  end

  @doc """
  Validates AWS Secret Access Key format (40+ character alphanumeric string).
  """
  def is_valid_secret_key?(secret_access_key) do
    is_binary(secret_access_key) and
      String.length(String.trim(secret_access_key)) >= 40 and
      String.match?(String.trim(secret_access_key), ~r/^[A-Za-z0-9+\/=]+$/)
  end

  @doc """
  Validates AWS region format (lowercase letters, numbers, and hyphens).
  """
  def is_valid_region?(region) do
    is_binary(region) and
      String.length(String.trim(region)) > 0 and
      String.match?(String.trim(region), ~r/^[a-z0-9-]+$/)
  end
end

defmodule GSMLG.AWS.HttpClient do
  require Logger

  @behaviour AWS.HTTPClient

  @impl true
  def request(
        method,
        url,
        body,
        headers,
        opts
      ) do
    opts = opts || []

    case client()
         |> Tesla.request(method: method, url: url, body: body, headers: headers, opts: opts) do
      {:ok, response} ->
        {:ok, %{status_code: response.status, headers: response.headers, body: response.body}}

      {:error, term} ->
        {:error, term}
    end
  end

  def client() do
    Tesla.client(
      [
        # {Tesla.Middleware.FollowRedirects, max_redirects: 3},
        Tesla.Middleware.JSON,
        # {Tesla.Middleware.Headers, [{"Accept", "application/json"}]},
        Tesla.Middleware.Logger
      ],
      {Tesla.Adapter.Finch, name: GSMLG.AWS.Finch}
    )
  end
end
