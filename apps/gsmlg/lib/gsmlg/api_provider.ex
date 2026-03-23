defmodule GSMLG.ApiProvider do
  @moduledoc """
  Schema for API provider credentials.

  Each record represents one named instance of an external API service.
  Multiple instances of the same provider type are supported (e.g., two
  different AWS accounts).

  ## Auth types

  - `"token"` — credentials set directly. Credentials map keys by provider:
    - github:     `%{token: "ghp_..."}`
    - openai:     `%{api_key: "sk-..."}`
    - deepseek:   `%{api_key: "..."}`
    - cloudflare: `%{api_token: "..."}` or `%{api_key: "...", email: "..."}`
    - aws:        `%{access_key_id: "AKIA...", secret_access_key: "..."}`

  - `"oauth"` — token obtained via OAuth2 flow. Credentials map keys:
    `%{client_id: "...", client_secret: "...", access_token: "...",
       refresh_token: "...", token_expires_at: unix_timestamp}`

  Sensitive credentials are AES-256-GCM encrypted at rest via `EncryptedMap`.
  Non-sensitive configuration (e.g., region, base_url) goes in `metadata`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.ApiProvider.EncryptedMap

  @valid_auth_types ~w[token oauth]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_providers" do
    field :provider, :string
    field :name, :string
    field :auth_type, :string, default: "token"
    field :credentials, EncryptedMap
    field :metadata, :map, default: %{}
    field :active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(api_provider, attrs) do
    api_provider
    |> cast(attrs, [:provider, :name, :auth_type, :credentials, :metadata, :active])
    |> validate_inclusion(:auth_type, @valid_auth_types)
  end

  @doc false
  def create_changeset(api_provider, attrs) do
    api_provider
    |> cast(attrs, [:provider, :name, :auth_type, :credentials, :metadata, :active])
    |> validate_required([:provider, :name])
    |> validate_inclusion(:auth_type, @valid_auth_types)
    |> unique_constraint([:provider, :name])
  end

  @doc false
  def update_changeset(api_provider, attrs) do
    api_provider
    |> cast(attrs, [:provider, :name, :auth_type, :credentials, :metadata, :active])
    |> validate_required([:provider, :name])
    |> validate_inclusion(:auth_type, @valid_auth_types)
    |> unique_constraint([:provider, :name])
  end

  @doc """
  Changeset for updating only OAuth tokens (access_token, refresh_token, token_expires_at).
  Used by the OAuth module after a token refresh.
  """
  def token_changeset(api_provider, credentials) do
    api_provider
    |> change(credentials: credentials)
  end
end
