defmodule GSMLG.ApiProvider.Vault do
  @moduledoc """
  In-memory store for API provider credentials backed by ETS.

  On startup the Vault attempts to auto-unseal: if `GSMLG_API_PROVIDER_KEY`
  is configured, all active providers are loaded from the database into ETS
  with their credentials already decrypted. When the key is absent the Vault
  starts in **sealed** state and returns `{:error, :sealed}` for all reads.

  ## Sealed / Unsealed

  - **Sealed**: ETS contains only the `{:__status__, :sealed}` sentinel.
    No plaintext credentials are held in memory.
  - **Unsealed**: ETS contains `{:__status__, :unsealed}` plus one entry per
    active provider keyed by `{provider_string, name_string}`.

  Mutations to providers (via `GSMLG.ApiProviders`) are broadcast over PubSub
  and reflected in ETS immediately without a full reload.

  ## Usage

      # Direct credential access
      GSMLG.ApiProvider.Vault.get("openai", "default")
      #=> {:ok, %GSMLG.ApiProvider{credentials: %{api_key: "sk-..."}}}

      # Token helper — handles OAuth refresh transparently
      GSMLG.ApiProvider.Vault.get_token("github", "default")
      #=> {:ok, "ghp_..."}
  """

  use GenServer
  require Logger

  alias GSMLG.ApiProviders
  alias GSMLG.ApiProvider.OAuth

  @ets_table :api_provider_vault
  @pubsub_topic "api_providers"

  # ---------------------------------------------------------------------------
  # Public API (direct ETS reads — no GenServer roundtrip)
  # ---------------------------------------------------------------------------

  @doc "Returns `{:ok, %ApiProvider{}}`, `:error`, or `{:error, :sealed}`."
  def get(provider, name) do
    case :ets.lookup(@ets_table, :__status__) do
      [{:__status__, :sealed}] ->
        {:error, :sealed}

      _ ->
        case :ets.lookup(@ets_table, {provider, name}) do
          [{_key, record}] -> {:ok, record}
          [] -> :error
        end
    end
  end

  @doc "Returns all active providers of `provider` type, or `[]` when sealed."
  def list(provider) do
    case :ets.lookup(@ets_table, :__status__) do
      [{:__status__, :sealed}] ->
        []

      _ ->
        :ets.match_object(@ets_table, {{provider, :_}, :_})
        |> Enum.map(fn {_k, v} -> v end)
    end
  end

  @doc "Returns all active providers, or `[]` when sealed."
  def all do
    case :ets.lookup(@ets_table, :__status__) do
      [{:__status__, :sealed}] ->
        []

      _ ->
        :ets.tab2list(@ets_table)
        |> Enum.reject(fn {k, _v} -> k == :__status__ end)
        |> Enum.map(fn {_k, v} -> v end)
    end
  end

  @doc "Returns `true` when the Vault is sealed."
  def sealed? do
    case :ets.lookup(@ets_table, :__status__) do
      [{:__status__, :sealed}] -> true
      _ -> false
    end
  end

  @doc """
  Returns `{:ok, token}` for the named provider, handling OAuth refresh
  transparently. Returns `:error` when provider is not found or
  `{:error, :sealed}` when the Vault is sealed.

  For `auth_type: "token"` returns `credentials.token` or `credentials.api_key`.
  For `auth_type: "oauth"` delegates to `GSMLG.ApiProvider.OAuth.ensure_valid_token/1`.
  """
  def get_token(provider, name) do
    case get(provider, name) do
      {:ok, %{auth_type: "token", credentials: creds}} ->
        token = creds[:token] || creds[:api_key] || creds[:api_token]
        if token, do: {:ok, token}, else: :error

      {:ok, %{auth_type: "oauth"} = api_provider} ->
        OAuth.ensure_valid_token(api_provider)

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # Control (GenServer calls)
  # ---------------------------------------------------------------------------

  @doc "Seals the Vault: clears all plaintext credentials from ETS."
  def seal, do: GenServer.call(__MODULE__, :seal)

  @doc "Unseals the Vault: loads active providers from DB into ETS."
  def unseal, do: GenServer.call(__MODULE__, :unseal)

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@ets_table, [:named_table, :set, :public, {:read_concurrency, true}])
    :ets.insert(@ets_table, {:__status__, :sealed})
    Phoenix.PubSub.subscribe(GSMLG.PubSub, @pubsub_topic)
    {:ok, %{sealed: true}, {:continue, :try_unseal}}
  end

  @impl true
  def handle_continue(:try_unseal, state) do
    if Application.get_env(:gsmlg, :api_provider_encryption_key) do
      do_unseal()
      Logger.info("[ApiProvider.Vault] Unsealed — providers loaded into memory.")
      {:noreply, %{state | sealed: false}}
    else
      Logger.warning("[ApiProvider.Vault] Sealed — GSMLG_API_PROVIDER_KEY not configured.")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:unseal, _from, state) do
    do_unseal()
    Logger.info("[ApiProvider.Vault] Unsealed.")
    {:reply, :ok, %{state | sealed: false}}
  end

  def handle_call(:seal, _from, state) do
    do_seal()
    Logger.info("[ApiProvider.Vault] Sealed — credentials cleared from memory.")
    {:reply, :ok, %{state | sealed: true}}
  end

  # PubSub: skip all events when sealed
  @impl true
  def handle_info(_, %{sealed: true} = state), do: {:noreply, state}

  def handle_info({:created, provider}, state) do
    if provider.active, do: ets_put(provider)
    {:noreply, state}
  end

  def handle_info({:updated, provider}, state) do
    :ets.delete(@ets_table, {provider.provider, provider.name})
    if provider.active, do: ets_put(provider)
    {:noreply, state}
  end

  def handle_info({:deleted, provider}, state) do
    :ets.delete(@ets_table, {provider.provider, provider.name})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_unseal do
    providers = ApiProviders.list_api_providers() |> Enum.filter(& &1.active)
    :ets.delete_all_objects(@ets_table)
    :ets.insert(@ets_table, {:__status__, :unsealed})
    Enum.each(providers, &ets_put/1)
    apply_app_env(providers)
  end

  defp do_seal do
    :ets.delete_all_objects(@ets_table)
    :ets.insert(@ets_table, {:__status__, :sealed})
    Application.delete_env(:gsmlg_aws, :aws_credentials)
  end

  # Push AWS credentials into :gsmlg_aws Application env so GSMLG.AWS.Client
  # can read them without a direct dependency on :gsmlg.
  defp apply_app_env(providers) do
    aws_creds =
      providers
      |> Enum.filter(&(&1.provider == "aws"))
      |> Map.new(fn p ->
        region = p.metadata["region"] || p.metadata[:region]

        {p.name,
         %{
           access_key_id: p.credentials[:access_key_id],
           secret_access_key: p.credentials[:secret_access_key],
           region: region
         }}
      end)

    Application.put_env(:gsmlg_aws, :aws_credentials, aws_creds)
  end

  defp ets_put(provider) do
    :ets.insert(@ets_table, {{provider.provider, provider.name}, provider})
  end
end
