defmodule GSMLG.Scout.Test.FakeLightpanda do
  @behaviour GSMLG.Scout.Agent.Lightpanda

  @impl true
  def fetch(url, _opts) do
    {:ok,
     %{
       final_url: url,
       title: "Example Documentation",
       markdown: "# Example Documentation\n\nFetched #{url}",
       status_code: 200
     }}
  end
end

defmodule GSMLG.Scout.Test.AllowRedirectGuard do
  @behaviour GSMLG.Scout.Agent.RedirectGuard

  @impl true
  def fetch(url, _settings, _timeout_ms) do
    {:ok,
     %{
       final_url: url,
       status_code: 200,
       content_type: "text/html; charset=utf-8",
       body: "<h1>Example Documentation</h1><p>Fetched #{url}</p>"
     }}
  end
end
