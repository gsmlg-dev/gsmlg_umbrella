defmodule GSMLG.SVG_Autocrop do
  use HTTPoison.Base
  require Logger

  defmacro process_result(result) do
    quote do
      case unquote(result) do
        {:ok,
         %HTTPoison.Response{
           body: data,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 200 and status_code < 300 ->
          Logger.info("#{__MODULE__} API Access Success",
            status_code: status_code,
            request_url: request_url
          )

          {:ok, data}

        {:ok,
         %HTTPoison.Response{
           body: data,
           status_code: 401,
           request: %HTTPoison.Request{url: request_url}
         }} ->
          Logger.info("#{__MODULE__} API Access Unauthorized Error",
            status_code: 401,
            request_url: request_url
          )

          {:error, data}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 400 and status_code < 500 ->
          Logger.info("#{__MODULE__} API Access Client Error",
            status_code: status_code,
            request_url: request_url,
            body: body
          )

          {:error, body}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 500 ->
          Logger.info("#{__MODULE__} API Access Server Error",
            status_code: status_code,
            request_url: request_url,
            body: body
          )

          {:error, body}

        {:error, %HTTPoison.Error{reason: reason} = error} ->
          Logger.info("#{__MODULE__} API HTTPoison.Error", reason: reason)
          {:error, reason}
      end
    end
  end

  def process_request_url(url) do
    "https://svg-autocrop.gsmlg.net" <> url
  end

  def process_response_body(body) do
    case Jason.decode(body, [{:keys, :atoms}]) do
      {:ok, resp} -> resp
      {:error, _} -> body
    end
  end

  def convert(data) do
    postData = Jason.encode!(data)

    post("/api/svg-autocrop", postData, [{"content-type", "application/json"}])
    |> process_result()
  end
end
