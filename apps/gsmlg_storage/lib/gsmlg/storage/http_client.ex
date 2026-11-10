defmodule GSMLG.Storage.HTTPClient do
  require Logger

  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(
        method,
        url,
        body,
        headers,
        opts
      ) do
    {decode_json, opts} = Keyword.pop(opts || [], :decode_json, true)

    case client(decode_json)
         |> Tesla.request(method: method, url: url, body: body, headers: headers, opts: opts) do
      {:ok, response} ->
        {:ok, %{status_code: response.status, headers: response.headers, body: response.body}}

      {:error, term} ->
        {:error, %{reason: term}}
    end
  end

  def client(), do: client(true)

  defp client(decode_json) do
    middleware =
      if decode_json,
        do: [Tesla.Middleware.JSON],
        else: []

    Tesla.client(
      middleware ++
        [
          # {Tesla.Middleware.FollowRedirects, max_redirects: 3},
          # {Tesla.Middleware.Headers, [{"Accept", "application/json"}]},
          {Tesla.Middleware.Logger, debug: false, filter_headers: ["authorization"]}
        ],
      GSMLG.HTTPFetchAdapter
    )
  end
end
