defmodule GSMLG.Commander.Policy do
  @moduledoc """
  Authorization policy enforcement for Commander operations.

  Provides access control rules based on:
  - User roles (agent, operator, admin)
  - Tag-based access matching
  - Explicit agent/hostname lists
  - Pattern matching on hostnames

  ## Access Rules

  | Role | Can Connect Agents | Can View Sessions | Can Attach PTY | Can Terminate | Admin API |
  |------|-------------------|-------------------|----------------|---------------|-----------|
  | Agent | Yes (own) | - | - | - | - |
  | Operator | - | Yes (authorized) | Yes (authorized) | Yes (own PTYs) | - |
  | Admin | - | Yes (all) | Yes (all) | Yes (all) | Yes |

  ## Configuration

  Policies can be configured in the application config:

  ```elixir
  config :gsmlg_commander, :policy,
    default_access: :none,
    enable_tag_matching: true,
    admin_users: ["admin@example.com"]
  ```

  ## Examples

      # Check if user can access an agent
      GSMLG.Commander.Policy.authorize(:spawn_pty, user_id, agent_metadata)

      # Check specific permission
      GSMLG.Commander.Policy.can?(:view_sessions, user_id)

  """

  require GSMLG.Telemetry

  @type user_id :: String.t()
  @type agent_id :: String.t()
  @type permission ::
          :spawn_pty
          | :view_sessions
          | :attach_pty
          | :terminate_session
          | :admin_api
          | :view_audit_log

  @type access_rule ::
          {:tags, [String.t()]}
          | {:agents, [agent_id()]}
          | {:pattern, Regex.t() | String.t()}
          | :all
          | :none

  @type user_policy :: %{
          user_id: user_id(),
          role: :agent | :operator | :admin,
          access_rules: [access_rule()],
          max_concurrent_ptys: pos_integer(),
          capabilities: [permission()]
        }

  @type agent_metadata :: %{
          optional(:agent_id) => String.t(),
          optional(:hostname) => String.t(),
          optional(:tags) => [String.t()],
          optional(:user_id) => String.t(),
          optional(atom()) => term()
        }

  # ============================================================================
  # Authorization Functions
  # ============================================================================

  @doc """
  Authorizes an action for a user against an agent.

  Returns `:ok` if authorized, `{:error, :unauthorized}` otherwise.

  ## Examples

      iex> Policy.authorize(:spawn_pty, "user123", %{agent_id: "agent1", tags: ["web"]})
      :ok

      iex> Policy.authorize(:admin_api, "user123", %{})
      {:error, :unauthorized}

  """
  @spec authorize(permission(), user_id(), agent_metadata()) :: :ok | {:error, :unauthorized}
  def authorize(permission, user_id, agent_metadata \\ %{}) do
    policy = get_user_policy(user_id)

    result =
      cond do
        # Admins can do everything
        policy.role == :admin ->
          :ok

        # Check if permission is in capabilities
        permission not in policy.capabilities ->
          {:error, :unauthorized}

        # Check access rules for agent-specific permissions
        permission in [:spawn_pty, :attach_pty, :terminate_session] ->
          if matches_access_rules?(policy.access_rules, agent_metadata) do
            :ok
          else
            {:error, :unauthorized}
          end

        # General permissions just need capability
        true ->
          :ok
      end

    log_authorization(permission, user_id, agent_metadata, result)
    result
  end

  @doc """
  Checks if a user has a specific permission.

  This is a simpler check that doesn't consider agent-specific rules.
  """
  @spec can?(permission(), user_id()) :: boolean()
  def can?(permission, user_id) do
    policy = get_user_policy(user_id)
    policy.role == :admin or permission in policy.capabilities
  end

  @doc """
  Checks if a user can access a specific agent.
  """
  @spec can_access_agent?(user_id(), agent_metadata()) :: boolean()
  def can_access_agent?(user_id, agent_metadata) do
    policy = get_user_policy(user_id)
    policy.role == :admin or matches_access_rules?(policy.access_rules, agent_metadata)
  end

  @doc """
  Returns the policy for a user.
  """
  @spec get_user_policy(user_id()) :: user_policy()
  def get_user_policy(user_id) do
    # Check if user is an admin
    admin_users = get_config(:admin_users, [])

    if user_id in admin_users do
      admin_policy(user_id)
    else
      # Check stored policies or return default
      stored_policy = get_stored_policy(user_id)
      stored_policy || default_policy(user_id)
    end
  end

  @doc """
  Creates or updates a user policy.
  """
  @spec set_user_policy(user_policy()) :: :ok
  def set_user_policy(policy) do
    # In a real implementation, this would persist to database
    # For now, we'll use ETS or application env
    policies = get_all_policies()
    new_policies = Map.put(policies, policy.user_id, policy)
    Application.put_env(:gsmlg_commander, :user_policies, new_policies)
    :ok
  end

  @doc """
  Deletes a user policy.
  """
  @spec delete_user_policy(user_id()) :: :ok
  def delete_user_policy(user_id) do
    policies = get_all_policies()
    new_policies = Map.delete(policies, user_id)
    Application.put_env(:gsmlg_commander, :user_policies, new_policies)
    :ok
  end

  @doc """
  Lists all user policies.
  """
  @spec list_policies() :: [user_policy()]
  def list_policies do
    get_all_policies()
    |> Map.values()
  end

  # ============================================================================
  # Rule Building Functions
  # ============================================================================

  @doc """
  Creates a tag-based access rule.

  Users with this rule can access agents that have ALL of the specified tags.
  """
  @spec tags_rule([String.t()]) :: access_rule()
  def tags_rule(tags) when is_list(tags) do
    {:tags, tags}
  end

  @doc """
  Creates an explicit agent list access rule.
  """
  @spec agents_rule([agent_id()]) :: access_rule()
  def agents_rule(agent_ids) when is_list(agent_ids) do
    {:agents, agent_ids}
  end

  @doc """
  Creates a hostname pattern access rule.

  Supports wildcards: `*` matches any characters, `?` matches single character.
  """
  @spec pattern_rule(String.t()) :: access_rule()
  def pattern_rule(pattern) when is_binary(pattern) do
    {:pattern, pattern}
  end

  @doc """
  Creates an all-access rule (admin-level).
  """
  @spec all_rule() :: access_rule()
  def all_rule, do: :all

  @doc """
  Creates a no-access rule.
  """
  @spec none_rule() :: access_rule()
  def none_rule, do: :none

  # ============================================================================
  # Policy Validation
  # ============================================================================

  @doc """
  Validates a user policy.
  """
  @spec validate_policy(user_policy()) :: :ok | {:error, [String.t()]}
  def validate_policy(policy) do
    errors =
      []
      |> validate_required_fields(policy)
      |> validate_role(policy)
      |> validate_capabilities(policy)
      |> validate_access_rules(policy)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_config(key, default) do
    config = Application.get_env(:gsmlg_commander, :policy, [])
    Keyword.get(config, key, default)
  end

  defp get_all_policies do
    Application.get_env(:gsmlg_commander, :user_policies, %{})
  end

  defp get_stored_policy(user_id) do
    policies = get_all_policies()
    Map.get(policies, user_id)
  end

  defp admin_policy(user_id) do
    %{
      user_id: user_id,
      role: :admin,
      access_rules: [:all],
      max_concurrent_ptys: 100,
      capabilities: [
        :spawn_pty,
        :view_sessions,
        :attach_pty,
        :terminate_session,
        :admin_api,
        :view_audit_log
      ]
    }
  end

  defp default_policy(user_id) do
    default_access = get_config(:default_access, :none)

    access_rules =
      case default_access do
        :none -> [:none]
        :tagged -> [{:tags, []}]
        :all -> [:all]
        _ -> [:none]
      end

    %{
      user_id: user_id,
      role: :operator,
      access_rules: access_rules,
      max_concurrent_ptys: get_config(:default_max_ptys, 5),
      capabilities: [:view_sessions]
    }
  end

  defp matches_access_rules?(rules, agent_metadata) do
    Enum.any?(rules, &matches_rule?(&1, agent_metadata))
  end

  defp matches_rule?(:all, _metadata), do: true
  defp matches_rule?(:none, _metadata), do: false

  defp matches_rule?({:tags, required_tags}, metadata) do
    agent_tags = metadata[:tags] || []
    Enum.all?(required_tags, &(&1 in agent_tags))
  end

  defp matches_rule?({:agents, agent_ids}, metadata) do
    agent_id = metadata[:agent_id]
    agent_id && agent_id in agent_ids
  end

  defp matches_rule?({:pattern, pattern}, metadata) when is_binary(pattern) do
    hostname = metadata[:hostname]

    if hostname do
      regex = pattern_to_regex(pattern)
      Regex.match?(regex, hostname)
    else
      false
    end
  end

  defp matches_rule?({:pattern, %Regex{} = regex}, metadata) do
    hostname = metadata[:hostname]
    hostname && Regex.match?(regex, hostname)
  end

  defp matches_rule?(_, _), do: false

  defp pattern_to_regex(pattern) do
    pattern
    |> String.replace(".", "\\.")
    |> String.replace("*", ".*")
    |> String.replace("?", ".")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end

  defp log_authorization(permission, user_id, agent_metadata, result) do
    status = if result == :ok, do: :allowed, else: :denied

    GSMLG.Telemetry.debug("Authorization check",
      permission: permission,
      user_id: user_id,
      agent_id: agent_metadata[:agent_id],
      hostname: agent_metadata[:hostname],
      result: status
    )

    :telemetry.execute(
      [:commander, :policy, :authorization],
      %{count: 1},
      %{
        permission: permission,
        user_id: user_id,
        result: status
      }
    )
  end

  defp validate_required_fields(errors, policy) do
    required = [:user_id, :role, :access_rules, :capabilities]

    Enum.reduce(required, errors, fn field, acc ->
      if Map.has_key?(policy, field) do
        acc
      else
        ["missing required field: #{field}" | acc]
      end
    end)
  end

  defp validate_role(errors, policy) do
    valid_roles = [:agent, :operator, :admin]

    if policy[:role] in valid_roles do
      errors
    else
      ["invalid role: #{inspect(policy[:role])}" | errors]
    end
  end

  defp validate_capabilities(errors, policy) do
    valid_caps = [
      :spawn_pty,
      :view_sessions,
      :attach_pty,
      :terminate_session,
      :admin_api,
      :view_audit_log
    ]

    invalid =
      (policy[:capabilities] || [])
      |> Enum.reject(&(&1 in valid_caps))

    if Enum.empty?(invalid) do
      errors
    else
      ["invalid capabilities: #{inspect(invalid)}" | errors]
    end
  end

  defp validate_access_rules(errors, policy) do
    rules = policy[:access_rules] || []

    invalid =
      Enum.reject(rules, fn
        :all -> true
        :none -> true
        {:tags, tags} when is_list(tags) -> true
        {:agents, ids} when is_list(ids) -> true
        {:pattern, p} when is_binary(p) -> true
        {:pattern, %Regex{}} -> true
        _ -> false
      end)

    if Enum.empty?(invalid) do
      errors
    else
      ["invalid access rules: #{inspect(invalid)}" | errors]
    end
  end
end
