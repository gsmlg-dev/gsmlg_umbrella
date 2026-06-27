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
