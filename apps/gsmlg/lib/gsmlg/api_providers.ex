defmodule GSMLG.ApiProviders do
  @moduledoc """
  Context for managing API provider credentials.

  Mutations broadcast via PubSub so `GSMLG.ApiProvider.Vault` keeps its
  in-memory ETS cache in sync without polling.
  """

  import Ecto.Query, warn: false
  alias GSMLG.Repo
  alias GSMLG.ApiProvider

  @pubsub_topic "api_providers"

  @doc """
  Returns all API providers.
  """
  def list_api_providers do
    Repo.all(ApiProvider)
  end

  @doc """
  Returns all API providers of a given provider type.
  """
  def list_api_providers(provider) do
    Repo.all(from p in ApiProvider, where: p.provider == ^provider)
  end

  @doc """
  Gets a single API provider by id. Raises if not found.
  """
  def get_api_provider!(id) do
    Repo.get!(ApiProvider, id)
  end

  @doc """
  Gets a single API provider by provider type and name. Returns nil if not found.
  """
  def get_api_provider_by(provider, name) do
    Repo.get_by(ApiProvider, provider: provider, name: name)
  end

  @doc """
  Creates an API provider.
  """
  def create_api_provider(attrs \\ %{}) do
    %ApiProvider{}
    |> ApiProvider.create_changeset(attrs)
    |> Repo.insert()
    |> broadcast(:created)
  end

  @doc """
  Updates an API provider.
  """
  def update_api_provider(%ApiProvider{} = api_provider, attrs) do
    api_provider
    |> ApiProvider.update_changeset(attrs)
    |> Repo.update()
    |> broadcast(:updated)
  end

  @doc """
  Updates only the OAuth tokens on a provider (called after token refresh).
  """
  def update_oauth_tokens(%ApiProvider{} = api_provider, credentials) do
    api_provider
    |> ApiProvider.token_changeset(credentials)
    |> Repo.update()
    |> broadcast(:updated)
  end

  @doc """
  Deletes an API provider.
  """
  def delete_api_provider(%ApiProvider{} = api_provider) do
    Repo.delete(api_provider)
    |> broadcast(:deleted)
  end

  @doc """
  Returns a changeset for tracking API provider changes.
  """
  def change_api_provider(%ApiProvider{} = api_provider, attrs \\ %{}) do
    ApiProvider.changeset(api_provider, attrs)
  end

  defp broadcast({:ok, api_provider} = result, event) do
    Phoenix.PubSub.broadcast(GSMLG.PubSub, @pubsub_topic, {event, api_provider})
    result
  end

  defp broadcast(error, _event), do: error
end
