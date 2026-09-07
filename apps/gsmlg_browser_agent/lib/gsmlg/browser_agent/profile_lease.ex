defmodule GSMLG.BrowserAgent.ProfileLease do
  @moduledoc "Pure authoritative profile lease transitions."

  @enforce_keys [
    :profile_id,
    :lease_id,
    :owner_type,
    :owner_id,
    :mode,
    :acquired_at,
    :heartbeat_at,
    :expires_at
  ]
  defstruct @enforce_keys ++ [suspended: nil]

  @type owner_type :: :automation | :manual
  @type mode :: :automation | :workflow | :manual
  @type t :: %__MODULE__{
          profile_id: String.t(),
          lease_id: String.t(),
          owner_type: owner_type(),
          owner_id: String.t(),
          mode: mode(),
          acquired_at: DateTime.t(),
          heartbeat_at: DateTime.t(),
          expires_at: DateTime.t(),
          suspended: t() | nil
        }

  @spec acquire(t() | nil, keyword()) :: {:ok, t()} | {:error, atom()}
  def acquire(nil, opts) do
    with :ok <- validate_base(opts),
         :ok <- validate_owner(Keyword.fetch!(opts, :owner_type), Keyword.fetch!(opts, :mode)) do
      now = Keyword.fetch!(opts, :now)

      {:ok,
       %__MODULE__{
         profile_id: Keyword.fetch!(opts, :profile_id),
         lease_id: Keyword.fetch!(opts, :lease_id),
         owner_type: Keyword.fetch!(opts, :owner_type),
         owner_id: Keyword.fetch!(opts, :owner_id),
         mode: Keyword.fetch!(opts, :mode),
         acquired_at: now,
         heartbeat_at: now,
         expires_at: DateTime.add(now, Keyword.fetch!(opts, :ttl_ms), :millisecond)
       }}
    end
  end

  def acquire(%__MODULE__{}, _opts), do: {:error, :profile_busy}

  @spec manual_handoff(t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def manual_handoff(%__MODULE__{owner_type: :automation, suspended: nil} = lease, opts) do
    with :ok <- validate_handoff(opts) do
      now = Keyword.fetch!(opts, :now)

      {:ok,
       %__MODULE__{
         profile_id: lease.profile_id,
         lease_id: Keyword.fetch!(opts, :lease_id),
         owner_type: :manual,
         owner_id: Keyword.fetch!(opts, :owner_id),
         mode: :manual,
         acquired_at: now,
         heartbeat_at: now,
         expires_at: DateTime.add(now, Keyword.fetch!(opts, :ttl_ms), :millisecond),
         suspended: lease
       }}
    end
  end

  def manual_handoff(%__MODULE__{}, _opts), do: {:error, :lease_conflict}

  @spec resume(t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def resume(%__MODULE__{owner_type: :manual, suspended: %__MODULE__{} = suspended}, opts) do
    with :ok <- validate_resume(opts) do
      now = Keyword.fetch!(opts, :now)

      {:ok,
       %{
         suspended
         | lease_id: Keyword.fetch!(opts, :lease_id),
           acquired_at: now,
           heartbeat_at: now,
           expires_at: DateTime.add(now, Keyword.fetch!(opts, :ttl_ms), :millisecond),
           suspended: nil
       }}
    end
  end

  def resume(%__MODULE__{}, _opts), do: {:error, :lease_conflict}

  @spec heartbeat(t(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, t()} | {:error, atom()}
  def heartbeat(%__MODULE__{lease_id: lease_id} = lease, lease_id, %DateTime{} = now, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    {:ok,
     %{
       lease
       | heartbeat_at: now,
         expires_at: DateTime.add(now, ttl_ms, :millisecond)
     }}
  end

  def heartbeat(%__MODULE__{}, _lease_id, _now, _ttl_ms), do: {:error, :lease_conflict}

  @spec release(t(), String.t()) :: {:ok, nil} | {:error, atom()}
  def release(%__MODULE__{lease_id: lease_id}, lease_id), do: {:ok, nil}
  def release(%__MODULE__{}, _lease_id), do: {:error, :lease_conflict}

  @spec reconcile(t(), keyword()) :: {:ok, t() | nil} | {:error, atom()}
  def reconcile(%__MODULE__{} = lease, opts) do
    with %DateTime{} = now <- Keyword.get(opts, :now),
         execution_active? when is_boolean(execution_active?) <-
           Keyword.get(opts, :execution_active?) do
      cond do
        DateTime.compare(lease.expires_at, now) == :gt -> {:ok, lease}
        execution_active? -> {:ok, lease}
        true -> {:ok, nil}
      end
    else
      _invalid -> {:error, :invalid_reconcile}
    end
  end

  defp validate_base(opts) do
    required_strings = [:profile_id, :lease_id, :owner_id]

    cond do
      not Enum.all?(required_strings, &valid_string?(Keyword.get(opts, &1))) ->
        {:error, :invalid_lease}

      not match?(%DateTime{}, Keyword.get(opts, :now)) ->
        {:error, :invalid_lease}

      not (is_integer(Keyword.get(opts, :ttl_ms)) and Keyword.get(opts, :ttl_ms) > 0) ->
        {:error, :invalid_lease}

      true ->
        :ok
    end
  end

  defp validate_handoff(opts) do
    if valid_string?(Keyword.get(opts, :lease_id)) and
         valid_string?(Keyword.get(opts, :owner_id)) and
         match?(%DateTime{}, Keyword.get(opts, :now)) and
         is_integer(Keyword.get(opts, :ttl_ms)) and Keyword.get(opts, :ttl_ms) > 0,
       do: :ok,
       else: {:error, :invalid_lease}
  end

  defp validate_resume(opts) do
    if valid_string?(Keyword.get(opts, :lease_id)) and
         match?(%DateTime{}, Keyword.get(opts, :now)) and
         is_integer(Keyword.get(opts, :ttl_ms)) and Keyword.get(opts, :ttl_ms) > 0,
       do: :ok,
       else: {:error, :invalid_lease}
  end

  defp validate_owner(:automation, mode) when mode in [:automation, :workflow], do: :ok
  defp validate_owner(:manual, :manual), do: :ok
  defp validate_owner(_owner_type, _mode), do: {:error, :invalid_lease}

  defp valid_string?(value), do: is_binary(value) and byte_size(value) > 0
end
