defmodule GSMLG.Commander.Token do
  @moduledoc """
  Token struct for commander agent authentication.

  Tokens allow commander agents to authenticate with the server.
  Each token has associated capabilities and auto-tags.
  """

  @type capability :: :shell | :files | :processes | :system_info | :logs | :metrics | :services

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          token_hash: String.t(),
          token_prefix: String.t(),
          capabilities: [capability()],
          auto_tags: [String.t()],
          expires_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          created_by: String.t(),
          last_used_at: DateTime.t() | nil,
          use_count: non_neg_integer(),
          revoked: boolean(),
          revoked_at: DateTime.t() | nil,
          revoked_by: String.t() | nil
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :token_prefix,
             :capabilities,
             :auto_tags,
             :expires_at,
             :created_at,
             :created_by,
             :last_used_at,
             :use_count,
             :revoked,
             :revoked_at,
             :revoked_by
           ]}

  defstruct [
    :id,
    :name,
    :description,
    :token_hash,
    :token_prefix,
    :capabilities,
    :auto_tags,
    :expires_at,
    :created_at,
    :created_by,
    :last_used_at,
    :use_count,
    :revoked,
    :revoked_at,
    :revoked_by
  ]

  @all_capabilities [:shell, :files, :processes, :system_info, :logs, :metrics, :services]

  @doc """
  Returns all available capabilities.
  """
  @spec all_capabilities() :: [capability()]
  def all_capabilities, do: @all_capabilities

  @doc """
  Creates a new Token struct with the given attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    struct(__MODULE__, Map.put_new(attrs, :use_count, 0))
  end

  @doc """
  Checks if the token is expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if the token is valid (not expired and not revoked).
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{revoked: true}), do: false
  def valid?(token), do: not expired?(token)

  @doc """
  Returns a sanitized version of the token (without token_hash).
  """
  @spec sanitize(t()) :: map()
  def sanitize(%__MODULE__{} = token) do
    token
    |> Map.from_struct()
    |> Map.delete(:token_hash)
  end

  @doc """
  Returns a human-readable status for the token.
  """
  @spec status(t()) :: :active | :expired | :revoked | :unused
  def status(%__MODULE__{revoked: true}), do: :revoked
  def status(%__MODULE__{} = token) do
    cond do
      expired?(token) -> :expired
      token.last_used_at == nil -> :unused
      true -> :active
    end
  end

  @doc """
  Checks if the token has a specific capability.
  """
  @spec has_capability?(t(), capability()) :: boolean()
  def has_capability?(%__MODULE__{capabilities: capabilities}, capability) do
    capability in capabilities
  end
end
