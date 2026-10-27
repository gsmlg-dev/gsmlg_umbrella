defmodule GSMLG.GaoNote.Compat.HTTP do
  @moduledoc false

  def post_json(url, headers, payload, max_bytes) do
    case Tesla.request(
           method: :post,
           url: url,
           headers: headers,
           body: Jason.encode!(payload),
           opts: [adapter: [receive_timeout: 15_000, max_body_bytes: max_bytes]]
         ) do
      {:ok, response} ->
        {:ok, %{status: response.status, body: response.body}}

      {:error, :response_limit} ->
        {:error, :response_limit}

      {:error, _} ->
        {:error, :service_unavailable}
    end
  end
end
