defmodule GSMLG.Commander.TokenManager do
  @moduledoc """
  GenServer that manages agent authentication tokens.

  Provides token generation, validation, and lifecycle management.
  Uses ETS for fast lookups and DETS for persistence across restarts.

  ## Token Format

  Tokens follow the format: `cmdr_tk_<48 base62 characters>`
  - Prefix: `cmdr_tk_`
  - Body: 48 characters of URL-safe base62 (a-zA-Z0-9)
  - Total: 56 characters

  ## Security

  - Plaintext tokens are only returned on generation
  - Tokens are hashed using Bcrypt before storage
  - Constant-time comparison for token validation
  """

  use GenServer
  require Logger

  alias GSMLG.Commander.Token

  @token_prefix "cmdr_tk_"
  @token_length 48
  @ets_table :commander_tokens
  @dets_file ~c"commander_tokens.dets"

  # Base62 alphabet for token generation
  @base62_alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # Public API

  @doc """
  Starts the TokenManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates a new authentication token.

  Returns the plaintext token ONLY on creation.

  ## Options

  - `:name` - Token name (required)
  - `:description` - Optional description
  - `:capabilities` - List of allowed capabilities (default: all)
  - `:auto_tags` - Tags to assign to commanders using this token
  - `:expires_in` - Expiration in seconds (optional)
  - `:expires_at` - Expiration DateTime (optional)
  - `:created_by` - User ID who created the token (required)

  ## Returns

  - `{:ok, %{token: plaintext, id: uuid}}` on success
  - `{:error, reason}` on failure
  """
  @spec generate_token(keyword()) ::
          {:ok, %{token: String.t(), id: String.t()}} | {:error, term()}
  def generate_token(opts) do
    GenServer.call(__MODULE__, {:generate_token, opts})
  end

  @doc """
  Validates a plaintext token.

  Updates last_used_at and use_count on success.

  ## Returns

  - `{:ok, %Token{}}` on valid token
  - `{:error, :invalid}` if token doesn't exist
  - `{:error, :expired}` if token is expired
  - `{:error, :revoked}` if token is revoked
  """
  @spec validate_token(String.t()) :: {:ok, Token.t()} | {:error, :invalid | :expired | :revoked}
  def validate_token(plaintext_token) do
    GenServer.call(__MODULE__, {:validate_token, plaintext_token})
  end

  @doc """
  Lists all tokens.

  ## Options

  - `:created_by` - Filter by creator
  - `:active_only` - Only return non-revoked, non-expired tokens
  - `:include_revoked` - Include revoked tokens (default: true)

  ## Returns

  List of Token structs with token_hash redacted.
  """
  @spec list_tokens(keyword()) :: [Token.t()]
  def list_tokens(opts \\ []) do
    GenServer.call(__MODULE__, {:list_tokens, opts})
  end

  @doc """
  Gets a token by ID.

  ## Returns

  - `{:ok, %Token{}}` with token_hash redacted
  - `{:error, :not_found}` if token doesn't exist
  """
  @spec get_token(String.t()) :: {:ok, Token.t()} | {:error, :not_found}
  def get_token(id) do
    GenServer.call(__MODULE__, {:get_token, id})
  end

  @doc """
  Revokes a token.

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec revoke_token(String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_token(id, revoked_by) do
    GenServer.call(__MODULE__, {:revoke_token, id, revoked_by})
  end

  @doc """
  Regenerates a token value, invalidating the old one.

  ## Returns

  - `{:ok, %{token: plaintext}}` on success
  - `{:error, reason}` on failure
  """
  @spec regenerate_token(String.t(), String.t()) :: {:ok, %{token: String.t()}} | {:error, term()}
  def regenerate_token(id, regenerated_by) do
    GenServer.call(__MODULE__, {:regenerate_token, id, regenerated_by})
  end

  @doc """
  Permanently deletes a token.

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec delete_token(String.t()) :: :ok | {:error, term()}
  def delete_token(id) do
    GenServer.call(__MODULE__, {:delete_token, id})
  end

  @doc """
  Cleans up expired tokens.

  ## Returns

  - `{:ok, count}` with number of tokens marked as expired
  """
  @spec cleanup_expired() :: {:ok, non_neg_integer()}
  def cleanup_expired do
    GenServer.call(__MODULE__, :cleanup_expired)
  end

  @doc """
  Gets the count of tokens by status.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Open DETS for persistence
    dets_path = get_dets_path()
    {:ok, dets_ref} = :dets.open_file(@dets_file, file: dets_path, type: :set)

    # Load tokens from DETS into ETS
    load_from_dets(dets_ref)

    # Schedule periodic persistence
    schedule_persistence()

    GSMLG.Telemetry.info("TokenManager started",
      metadata: %{
        dets_path: to_string(dets_path),
        token_count: :ets.info(@ets_table, :size)
      }
    )

    {:ok, %{dets_ref: dets_ref}}
  end

  @impl true
  def handle_call({:generate_token, opts}, _from, state) do
    result = do_generate_token(opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate_token, plaintext_token}, _from, state) do
    result = do_validate_token(plaintext_token, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tokens, opts}, _from, state) do
    result = do_list_tokens(opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_token, id}, _from, state) do
    result = do_get_token(id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke_token, id, revoked_by}, _from, state) do
    result = do_revoke_token(id, revoked_by, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:regenerate_token, id, regenerated_by}, _from, state) do
    result = do_regenerate_token(id, regenerated_by, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_token, id}, _from, state) do
    result = do_delete_token(id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:cleanup_expired, _from, state) do
    result = do_cleanup_expired(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    result = do_stats()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:persist, state) do
    persist_to_dets(state.dets_ref)
    schedule_persistence()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist_to_dets(state.dets_ref)
    :dets.close(state.dets_ref)
    :ok
  end

  # Private Functions

  defp do_generate_token(opts, state) do
    with {:ok, name} <- validate_required(opts, :name),
         {:ok, created_by} <- validate_required(opts, :created_by) do
      # Generate token
      plaintext_token = generate_plaintext_token()
      token_hash = hash_token(plaintext_token)
      token_prefix = String.slice(plaintext_token, 0, 16)
      id = generate_uuid()

      # Calculate expiration
      expires_at = calculate_expiration(opts)

      # Build token struct
      token =
        Token.new(%{
          id: id,
          name: name,
          description: Keyword.get(opts, :description),
          token_hash: token_hash,
          token_prefix: token_prefix,
          capabilities: Keyword.get(opts, :capabilities, Token.all_capabilities()),
          auto_tags: Keyword.get(opts, :auto_tags, []),
          expires_at: expires_at,
          created_at: DateTime.utc_now(),
          created_by: created_by,
          last_used_at: nil,
          use_count: 0,
          revoked: false,
          revoked_at: nil,
          revoked_by: nil
        })

      # Store in ETS
      :ets.insert(@ets_table, {id, token})

      # Persist to DETS
      :dets.insert(state.dets_ref, {id, token})

      # Emit telemetry
      GSMLG.Telemetry.info("Token generated",
        metadata: %{
          token_id: id,
          token_name: name,
          created_by: created_by,
          expires_at: expires_at
        }
      )

      {:ok, %{token: plaintext_token, id: id}}
    end
  end

  defp do_validate_token(plaintext_token, state) do
    # Find token by trying to match hash
    case find_token_by_hash(plaintext_token) do
      nil ->
        GSMLG.Telemetry.warn("Token validation failed: invalid token",
          metadata: %{token_prefix: String.slice(plaintext_token, 0, 16)}
        )

        {:error, :invalid}

      token ->
        cond do
          token.revoked ->
            GSMLG.Telemetry.warn("Token validation failed: revoked",
              metadata: %{token_id: token.id}
            )

            {:error, :revoked}

          Token.expired?(token) ->
            GSMLG.Telemetry.warn("Token validation failed: expired",
              metadata: %{token_id: token.id}
            )

            {:error, :expired}

          true ->
            # Update usage stats
            updated_token = %{
              token
              | last_used_at: DateTime.utc_now(),
                use_count: token.use_count + 1
            }

            :ets.insert(@ets_table, {token.id, updated_token})
            :dets.insert(state.dets_ref, {token.id, updated_token})

            GSMLG.Telemetry.info("Token validated successfully",
              metadata: %{token_id: token.id, use_count: updated_token.use_count}
            )

            {:ok, updated_token}
        end
    end
  end

  defp do_list_tokens(opts) do
    tokens =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_id, token} -> token end)
      |> filter_tokens(opts)
      |> Enum.map(&sanitize_token/1)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    tokens
  end

  defp do_get_token(id) do
    case :ets.lookup(@ets_table, id) do
      [{^id, token}] -> {:ok, sanitize_token(token)}
      [] -> {:error, :not_found}
    end
  end

  defp do_revoke_token(id, revoked_by, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, token}] ->
        updated_token = %{
          token
          | revoked: true,
            revoked_at: DateTime.utc_now(),
            revoked_by: revoked_by
        }

        :ets.insert(@ets_table, {id, updated_token})
        :dets.insert(state.dets_ref, {id, updated_token})

        # Notify about revocation
        Phoenix.PubSub.broadcast(
          GSMLG.PubSub,
          "commander:tokens",
          {:token_revoked, id}
        )

        GSMLG.Telemetry.info("Token revoked",
          metadata: %{token_id: id, revoked_by: revoked_by}
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  defp do_regenerate_token(id, regenerated_by, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, token}] ->
        # Generate new token value
        plaintext_token = generate_plaintext_token()
        token_hash = hash_token(plaintext_token)
        token_prefix = String.slice(plaintext_token, 0, 16)

        updated_token = %{
          token
          | token_hash: token_hash,
            token_prefix: token_prefix
        }

        :ets.insert(@ets_table, {id, updated_token})
        :dets.insert(state.dets_ref, {id, updated_token})

        GSMLG.Telemetry.info("Token regenerated",
          metadata: %{token_id: id, regenerated_by: regenerated_by}
        )

        {:ok, %{token: plaintext_token}}

      [] ->
        {:error, :not_found}
    end
  end

  defp do_delete_token(id, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, _token}] ->
        :ets.delete(@ets_table, id)
        :dets.delete(state.dets_ref, id)

        GSMLG.Telemetry.info("Token deleted", metadata: %{token_id: id})

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  defp do_cleanup_expired(state) do
    now = DateTime.utc_now()

    expired_count =
      :ets.tab2list(@ets_table)
      |> Enum.filter(fn {_id, token} ->
        token.expires_at != nil and DateTime.compare(now, token.expires_at) == :gt and
          not token.revoked
      end)
      |> Enum.map(fn {id, token} ->
        updated_token = %{
          token
          | revoked: true,
            revoked_at: now,
            revoked_by: "system:expired"
        }

        :ets.insert(@ets_table, {id, updated_token})
        :dets.insert(state.dets_ref, {id, updated_token})
        id
      end)
      |> length()

    if expired_count > 0 do
      GSMLG.Telemetry.info("Cleaned up expired tokens",
        metadata: %{expired_count: expired_count}
      )
    end

    {:ok, expired_count}
  end

  defp do_stats do
    tokens = :ets.tab2list(@ets_table) |> Enum.map(fn {_id, token} -> token end)

    %{
      total: length(tokens),
      active: Enum.count(tokens, &Token.valid?/1),
      revoked: Enum.count(tokens, & &1.revoked),
      expired: Enum.count(tokens, &(not &1.revoked and Token.expired?(&1))),
      unused: Enum.count(tokens, &(&1.last_used_at == nil and Token.valid?(&1)))
    }
  end

  # Helper Functions

  defp generate_plaintext_token do
    random_part =
      1..@token_length
      |> Enum.map(fn _ -> Enum.random(@base62_alphabet) end)
      |> List.to_string()

    @token_prefix <> random_part
  end

  defp hash_token(plaintext_token) do
    Bcrypt.hash_pwd_salt(plaintext_token)
  end

  defp verify_token(plaintext_token, hash) do
    Bcrypt.verify_pass(plaintext_token, hash)
  end

  defp find_token_by_hash(plaintext_token) do
    # Search through all tokens (not optimal but secure)
    :ets.tab2list(@ets_table)
    |> Enum.find(fn {_id, token} ->
      verify_token(plaintext_token, token.token_hash)
    end)
    |> case do
      {_id, token} -> token
      nil -> nil
    end
  end

  defp filter_tokens(tokens, opts) do
    tokens
    |> maybe_filter_by_creator(Keyword.get(opts, :created_by))
    |> maybe_filter_active_only(Keyword.get(opts, :active_only, false))
    |> maybe_exclude_revoked(Keyword.get(opts, :include_revoked, true))
  end

  defp maybe_filter_by_creator(tokens, nil), do: tokens

  defp maybe_filter_by_creator(tokens, created_by) do
    Enum.filter(tokens, &(&1.created_by == created_by))
  end

  defp maybe_filter_active_only(tokens, false), do: tokens

  defp maybe_filter_active_only(tokens, true) do
    Enum.filter(tokens, &Token.valid?/1)
  end

  defp maybe_exclude_revoked(tokens, true), do: tokens

  defp maybe_exclude_revoked(tokens, false) do
    Enum.filter(tokens, &(not &1.revoked))
  end

  defp sanitize_token(token) do
    %{token | token_hash: "[REDACTED]"}
  end

  defp validate_required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  defp calculate_expiration(opts) do
    cond do
      expires_at = Keyword.get(opts, :expires_at) ->
        expires_at

      expires_in = Keyword.get(opts, :expires_in) ->
        DateTime.utc_now() |> DateTime.add(expires_in, :second)

      true ->
        nil
    end
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  defp get_dets_path do
    priv_dir = :code.priv_dir(:gsmlg_commander) || ~c"priv"
    # Ensure directory exists
    :filelib.ensure_dir(priv_dir ++ ~c"/")
    priv_dir ++ ~c"/" ++ @dets_file
  end

  defp load_from_dets(dets_ref) do
    :dets.foldl(
      fn {id, token}, _acc ->
        :ets.insert(@ets_table, {id, token})
        :ok
      end,
      :ok,
      dets_ref
    )
  end

  defp persist_to_dets(dets_ref) do
    :ets.foldl(
      fn {id, token}, _acc ->
        :dets.insert(dets_ref, {id, token})
        :ok
      end,
      :ok,
      @ets_table
    )

    :dets.sync(dets_ref)
  end

  defp schedule_persistence do
    # Persist every 5 minutes
    Process.send_after(self(), :persist, :timer.minutes(5))
  end
end
