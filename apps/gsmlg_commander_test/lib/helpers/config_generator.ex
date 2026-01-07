defmodule GSMLG.CommanderTest.Helpers.ConfigGenerator do
  @moduledoc """
  Generate TOML configuration files for test agents.

  Creates temporary configuration files in the GSMLG TOML format
  that test agents can load.

  """

  @doc """
  Generate a TOML configuration file for a test agent.

  ## Options

    * `:server_url` - WebSocket URL for the server
    * `:token` - Authentication token
    * `:hostname` - Agent hostname
    * `:agent_id` - Unique agent identifier
    * `:capabilities` - List of capabilities to enable

  ## Returns

    * `{:ok, path}` - Path to the generated config file
    * `{:error, reason}` - Failed to generate config

  """
  @spec generate_agent_config(map()) :: {:ok, String.t()} | {:error, term()}
  def generate_agent_config(opts) do
    config = build_config(opts)
    agent_id = Map.get(opts, :agent_id, generate_id())
    path = config_path(agent_id)

    case File.write(path, config) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Clean up a configuration file.
  """
  @spec cleanup_config(String.t()) :: :ok
  def cleanup_config(path) do
    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Clean up all test configuration files.
  """
  @spec cleanup_all() :: :ok
  def cleanup_all do
    config_dir()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "commander_test_"))
    |> Enum.each(fn file ->
      Path.join(config_dir(), file) |> File.rm()
    end)

    :ok
  rescue
    _ -> :ok
  end

  # Private functions

  defp build_config(opts) do
    server_url = Map.get(opts, :server_url, "ws://localhost:14000/agent/connect")
    token = Map.get(opts, :token, "test_token")
    hostname = Map.get(opts, :hostname, "test-agent")
    agent_id = Map.get(opts, :agent_id, generate_id())
    capabilities = Map.get(opts, :capabilities, [:shell, :files, :processes, :system_info])

    heartbeat_interval = Map.get(opts, :heartbeat_interval, 5)
    reconnect_initial_delay = Map.get(opts, :reconnect_initial_delay, 1)
    reconnect_max_delay = Map.get(opts, :reconnect_max_delay, 10)

    default_shell = Map.get(opts, :default_shell, "/bin/bash")
    default_term = Map.get(opts, :default_term, "xterm-256color")
    max_sessions = Map.get(opts, :max_sessions, 5)

    capabilities_section =
      capabilities
      |> Enum.map(&"#{&1} = true")
      |> Enum.join("\n")

    """
    # Generated test configuration for Commander agent
    # Agent ID: #{agent_id}
    # Generated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    [server]
    url = "#{server_url}"
    token = "#{token}"

    [agent]
    hostname = "#{hostname}"
    id = "#{agent_id}"

    [connection]
    heartbeat_interval = #{heartbeat_interval}
    reconnect_initial_delay = #{reconnect_initial_delay}
    reconnect_max_delay = #{reconnect_max_delay}

    [pty]
    default_shell = "#{default_shell}"
    default_term = "#{default_term}"
    max_sessions = #{max_sessions}

    [capabilities]
    #{capabilities_section}
    """
  end

  defp config_path(agent_id) do
    Path.join(config_dir(), "commander_test_#{agent_id}.toml")
  end

  defp config_dir do
    System.tmp_dir!()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
