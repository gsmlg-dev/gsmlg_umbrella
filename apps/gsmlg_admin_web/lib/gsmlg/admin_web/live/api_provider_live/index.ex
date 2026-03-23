defmodule GSMLG.AdminWeb.ApiProviderLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.ApiProviders
  alias GSMLG.ApiProvider

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, providers: [], active_menu: "api_providers")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "API Providers")
    |> assign(:providers, ApiProviders.list_api_providers())
  end

  defp apply_action(socket, :new, _params) do
    provider = %ApiProvider{}
    changeset = ApiProviders.change_api_provider(provider)

    socket
    |> assign(:page_title, "New API Provider")
    |> assign(:changeset, changeset)
    |> assign(:provider, provider)
    |> assign(:credentials_json, "")
    |> assign(:metadata_json, "{}")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    provider = ApiProviders.get_api_provider!(id)
    changeset = ApiProviders.change_api_provider(provider)
    credentials_json = Jason.encode!(provider.credentials || %{}, pretty: true)
    metadata_json = Jason.encode!(provider.metadata || %{}, pretty: true)

    socket
    |> assign(:page_title, "Edit API Provider")
    |> assign(:changeset, changeset)
    |> assign(:provider, provider)
    |> assign(:credentials_json, credentials_json)
    |> assign(:metadata_json, metadata_json)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(:page_title, "API Provider")
    |> assign(:provider, ApiProviders.get_api_provider!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    provider = ApiProviders.get_api_provider!(id)
    {:ok, _} = ApiProviders.delete_api_provider(provider)

    {:noreply,
     socket
     |> put_flash(:info, "Provider deleted")
     |> assign(:providers, ApiProviders.list_api_providers())}
  end

  def handle_event("validate", %{"api_provider" => params}, socket) do
    changeset =
      socket.assigns.provider
      |> ApiProviders.change_api_provider(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:credentials_json, params["credentials_json"] || "")
     |> assign(:metadata_json, params["metadata_json"] || "{}")}
  end

  def handle_event("save", %{"api_provider" => params}, socket) do
    save_provider(socket, socket.assigns.live_action, normalize_params(params))
  end

  defp save_provider(socket, :new, params) do
    case ApiProviders.create_api_provider(params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "API provider created")
         |> push_navigate(to: ~p"/api_providers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp save_provider(socket, :edit, params) do
    case ApiProviders.update_api_provider(socket.assigns.provider, params) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "API provider updated")
         |> push_navigate(to: ~p"/api_providers/#{provider.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  # Parse credentials_json and metadata_json strings into maps for changeset casting
  defp normalize_params(params) do
    params
    |> parse_json_field("credentials_json", "credentials")
    |> parse_json_field("metadata_json", "metadata")
  end

  defp parse_json_field(params, json_key, target_key) do
    case params[json_key] do
      nil ->
        params

      json when is_binary(json) ->
        value =
          case Jason.decode(json, keys: :atoms) do
            {:ok, map} when is_map(map) -> map
            _ -> nil
          end

        params
        |> Map.delete(json_key)
        |> Map.put(target_key, value)
    end
  end
end
