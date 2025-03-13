defmodule GSMLG.GitHub do
  require Logger

  def client() do
    token = System.get_env("GITHUB_TOKEN")

    Tesla.client(
      [
        {Tesla.Middleware.FollowRedirects, max_redirects: 1},
        {Tesla.Middleware.BaseUrl, "https://api.github.com"},
        if(token, do: {Tesla.Middleware.BearerAuth, token: token}),
        Tesla.Middleware.JSON,
        Tesla.Middleware.Logger
      ]
      |> Enum.filter(& &1)
    )
  end

  def fetch_repos(name, opts \\ []) do
    is_user = Keyword.get(opts, :is_user, false)
    type = if(is_user, do: "users", else: "orgs")

    case Tesla.get(client(), "/#{type}/#{name}/repos") do
      {:ok, %Tesla.Env{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} when status >= 400 and status < 500 ->
        {:error, body}

      {:ok, %Tesla.Env{status: status, body: body}} when status >= 500 ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch list of repositories of {name} from Github
  """
  @spec fetch_repos_cache(binary(), [{:is_user, boolean()}, {:ttl, integer()}]) :: List.t()
  def fetch_repos_cache(name, opts \\ []) do
    {ttl, opts} = Keyword.pop(opts, :ttl, 3600)
    GSMLG.SimpleCache.get(__MODULE__, :fetch_repos, [name, opts], ttl: ttl)
  end
end
