defmodule GSMLG.ApiProviderFixtures do
  @moduledoc """
  Test fixtures for `GSMLG.ApiProvider`.
  """

  alias GSMLG.ApiProviders

  def api_provider_fixture(attrs \\ %{}) do
    {:ok, api_provider} =
      attrs
      |> Enum.into(%{
        provider: "openai",
        name: "default-#{System.unique_integer([:positive])}",
        credentials: %{api_key: "sk-test-key"}
      })
      |> ApiProviders.create_api_provider()

    api_provider
  end
end
