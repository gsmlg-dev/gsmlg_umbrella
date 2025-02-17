defmodule GSMLG.AWS.Client do
  require Logger

  def get_client() do
    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    region = System.get_env("AWS_REGION")

    client =
      AWS.Client.create(access_key_id, secret_access_key, region)
      |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, []})
    # client = %AWS.Client{client | json_module: AWS.JSON}
    client
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
    opts = opts |> Keyword.put(:transport_opts, proxy: {:http, "10.100.0.1", 3128, []})

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
        # Tesla.Middleware.JSON,
        # {Tesla.Middleware.Headers, [{"Accept", "application/json"}, {"content-type", "application/json"}]},
        Tesla.Middleware.Logger
      ],
      {Tesla.Adapter.Finch, name: GSMLG.Finch}
    )
  end
end
