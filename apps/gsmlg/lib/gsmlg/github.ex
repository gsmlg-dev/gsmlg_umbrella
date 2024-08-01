defmodule GSMLG.GitHub do
  use HTTPoison.Base

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
          IO.inspect({"Access Success", status_code, request_url})
          {:ok, data}

        {:ok,
         %HTTPoison.Response{
           body: data,
           status_code: 401,
           request: %HTTPoison.Request{url: request_url}
         }} ->
          IO.inspect({"Unauthorized Error", 401, request_url})
          {:error, data}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 400 and status_code < 500 ->
          IO.inspect({"Client Error", status_code, request_url, body})
          {:error, body}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 500 ->
          IO.inspect({"Server Error", status_code, request_url, body})
          {:error, body}

        {:error, %HTTPoison.Error{reason: reason} = error} ->
          IO.inspect({"HTTPoison.Error", error})
          {:error, reason}
      end
    end
  end

  def process_request_url(url) do
    "https://api.github.com" <> url
  end

  def process_response_body(body) do
    case Jason.decode(body, [{:keys, :atoms}]) do
      {:ok, resp} -> resp
      {:error, _} -> body
    end
  end

  def fetch_repos() do
    case get("/orgs/gsmlg-dev/repos") |> process_result() do
      {:ok, data} ->
        data

      {:error, _} ->
        [
          %{
            name: "Foundation",
            full_name: "gsmlg-dev/Foundation",
            stargazers_count: 50,
            updated_at: "",
            description: "",
            has_pages: false,
            owner: %{
              login: "gsmlg-dev"
            }
          }
        ]
    end
  end

  @spec repos :: List.t()
  def repos() do
    GSMLG.SimpleCache.get(__MODULE__, :fetch_repos, [], ttl: 3600)
  end
end
