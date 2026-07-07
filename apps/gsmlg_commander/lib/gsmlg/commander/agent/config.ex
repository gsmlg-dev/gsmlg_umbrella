defmodule GSMLG.Commander.Agent.Config do
  @moduledoc """
  Load and manage agent configuration from TOML files.

  Configuration files are searched in the following order:
  1. Path provided explicitly
  2. `/etc/commander/agent.toml`
  3. `~/.config/commander/agent.toml`
  4. `./agent.toml`

  ## Configuration Schema

  ```toml
  [server]
  url = "wss://control.example.com/agent/connect"
  token = "cmdr_tk_your_token_here"

  [agent]
  hostname = "web-prod-01"
  id = "unique-agent-identifier"

  [connection]
  heartbeat_interval = 30
  reconnect_initial_delay = 1
  reconnect_max_delay = 60
  reconnect_backoff_multiplier = 2.0

  [pty]
  default_shell = "/bin/bash"
  default_term = "xterm-256color"
  max_sessions = 10
  idle_timeout = 3600

  [security]
  allowed_shells = ["/bin/bash", "/bin/zsh", "/bin/sh"]
  command_blocklist = ["rm -rf /", "mkfs", "dd if="]

  [limits]
  max_output_rate = 1048576
  max_buffer_size = 65536
  ```
  """

  require GSMLG.Telemetry

  @config_paths [
    "/etc/commander/agent.toml",
    "~/.config/commander/agent.toml",
    "./agent.toml"
  ]

  @default_config %{
    server: %{
      url: nil,
      token: nil
    },
    agent: %{
      hostname: nil,
      id: nil
    },
    connection: %{
      heartbeat_interval: 30,
      reconnect_initial_delay: 1,
      reconnect_max_delay: 60,
      reconnect_backoff_multiplier: 2.0
    },
    pty: %{
      default_shell: "/bin/bash",
      default_term: "xterm-256color",
      max_sessions: 10,
      idle_timeout: 3600
    },
    security: %{
      allowed_shells: ["/bin/bash", "/bin/zsh", "/bin/sh"],
      command_blocklist: []
    },
    limits: %{
      max_output_rate: 1_048_576,
      max_buffer_size: 65_536
    }
  }

  @type t :: %{
          server: %{
            url: String.t() | nil,
            token: String.t() | nil
          },
          agent: %{
            hostname: String.t() | nil,
            id: String.t() | nil
          },
          connection: %{
            heartbeat_interval: pos_integer(),
            reconnect_initial_delay: pos_integer(),
            reconnect_max_delay: pos_integer(),
            reconnect_backoff_multiplier: float()
          },
          pty: %{
            default_shell: String.t(),
            default_term: String.t(),
            max_sessions: pos_integer(),
            idle_timeout: pos_integer()
          },
          security: %{
            allowed_shells: [String.t()],
            command_blocklist: [String.t()]
          },
          limits: %{
            max_output_rate: pos_integer(),
            max_buffer_size: pos_integer()
          }
        }

  @doc """
  Loads agent configuration from a TOML file.

  If no path is provided, searches default locations in order.

  ## Options

    * `:path` - explicit path to configuration file
    * `:validate` - whether to validate the configuration (default: true)

  ## Returns

    * `{:ok, config}` - successfully loaded and parsed configuration
    * `{:error, reason}` - configuration loading failed

  ## Examples

      iex> GSMLG.Commander.Agent.Config.load()
      {:ok, %{server: %{url: "wss://..."}, ...}}

      iex> GSMLG.Commander.Agent.Config.load(path: "/custom/path.toml")
      {:ok, %{server: %{url: "wss://..."}, ...}}

  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    config_path = Keyword.get(opts, :path) || find_config()
    validate? = Keyword.get(opts, :validate, true)

    GSMLG.Telemetry.debug("Loading agent configuration",
      path: config_path,
      validate: validate?
    )

    with {:ok, path} <- ensure_config_exists(config_path),
         {:ok, raw_config} <- parse_toml_file(path),
         config <- normalize(raw_config),
         :ok <- maybe_validate(config, validate?) do
      GSMLG.Telemetry.info("Agent configuration loaded successfully",
        path: path,
        agent_id: get_in(config, [:agent, :id]),
        hostname: get_in(config, [:agent, :hostname])
      )

      {:ok, config}
    else
      {:error, reason} = error ->
        GSMLG.Telemetry.error("Failed to load agent configuration",
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Same as `load/1` but raises on error.
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "Failed to load config: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the default configuration.
  """
  @spec default_config() :: t()
  def default_config do
    @default_config
  end

  @doc """
  Merges custom configuration with defaults.
  """
  @spec merge_with_defaults(map()) :: t()
  def merge_with_defaults(custom_config) do
    deep_merge(@default_config, custom_config)
  end

  @doc """
  Validates a configuration map.

  ## Returns

    * `:ok` - configuration is valid
    * `{:error, reasons}` - list of validation errors

  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(config) do
    errors =
      []
      |> validate_server(config)
      |> validate_connection(config)
      |> validate_pty(config)
      |> validate_limits(config)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Gets a specific configuration value.

  ## Examples

      iex> config = GSMLG.Commander.Agent.Config.load!()
      iex> GSMLG.Commander.Agent.Config.get(config, [:server, :url])
      "wss://control.example.com/agent/connect"

  """
  @spec get(t(), atom() | [atom()]) :: term()
  def get(config, key) when is_atom(key) do
    Map.get(config, key)
  end

  def get(config, keys) when is_list(keys) do
    get_in(config, keys)
  end

  @doc """
  Gets a specific configuration value with a default.
  """
  @spec get(t(), atom() | [atom()], term()) :: term()
  def get(config, key, default) when is_atom(key) do
    Map.get(config, key, default)
  end

  def get(config, keys, default) when is_list(keys) do
    get_in(config, keys) || default
  end

  @doc """
  Gets the effective hostname, falling back to system hostname.
  """
  @spec effective_hostname(t()) :: String.t()
  def effective_hostname(config) do
    case get(config, [:agent, :hostname]) do
      nil -> system_hostname()
      hostname -> hostname
    end
  end

  @doc """
  Gets the effective agent ID, generating one if not configured.
  """
  @spec effective_agent_id(t()) :: String.t()
  def effective_agent_id(config) do
    case get(config, [:agent, :id]) do
      nil -> generate_agent_id()
      id -> id
    end
  end

  @doc """
  Gets the effective shell, checking if allowed.
  """
  @spec effective_shell(t()) :: {:ok, String.t()} | {:error, :shell_not_allowed}
  def effective_shell(config) do
    shell = get(config, [:pty, :default_shell]) || System.get_env("SHELL") || "/bin/bash"
    allowed_shells = get(config, [:security, :allowed_shells])

    if shell in allowed_shells do
      {:ok, shell}
    else
      {:error, :shell_not_allowed}
    end
  end

  @doc """
  Checks if a command is blocked by security policy.
  """
  @spec command_blocked?(t(), String.t()) :: boolean()
  def command_blocked?(config, command) do
    blocklist = get(config, [:security, :command_blocklist])

    Enum.any?(blocklist, fn blocked ->
      String.contains?(command, blocked)
    end)
  end

  @doc """
  Returns connection settings as a keyword list for use with clients.
  """
  @spec connection_opts(t()) :: keyword()
  def connection_opts(config) do
    connection = get(config, :connection)

    [
      heartbeat_interval: connection.heartbeat_interval * 1000,
      reconnect_initial_delay: connection.reconnect_initial_delay * 1000,
      reconnect_max_delay: connection.reconnect_max_delay * 1000,
      reconnect_backoff_multiplier: connection.reconnect_backoff_multiplier
    ]
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_config do
    @config_paths
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&File.exists?/1)
  end

  defp ensure_config_exists(nil), do: {:error, :config_not_found}

  defp ensure_config_exists(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      {:ok, expanded}
    else
      {:error, {:file_not_found, expanded}}
    end
  end

  defp parse_toml_file(path) do
    case Toml.decode_file(path, keys: :atoms) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error, {:toml_parse_error, reason}}
    end
  end

  defp normalize(raw_config) do
    @default_config
    |> deep_merge(raw_config)
    |> apply_environment_overrides()
  end

  defp apply_environment_overrides(config) do
    overrides = [
      {[:server, :url], "COMMANDER_SERVER_URL"},
      {[:server, :token], "COMMANDER_TOKEN"},
      {[:agent, :hostname], "COMMANDER_HOSTNAME"},
      {[:agent, :id], "COMMANDER_AGENT_ID"}
    ]

    Enum.reduce(overrides, config, fn {path, env_var}, acc ->
      case System.get_env(env_var) do
        nil -> acc
        value -> put_in(acc, path, value)
      end
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      deep_merge(left_val, right_val)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp maybe_validate(_config, false), do: :ok
  defp maybe_validate(config, true), do: validate(config)

  defp validate_server(errors, config) do
    url = get(config, [:server, :url])

    cond do
      is_nil(url) ->
        ["server.url is required" | errors]

      not String.starts_with?(url, ["ws://", "wss://"]) ->
        ["server.url must be a WebSocket URL (ws:// or wss://)" | errors]

      true ->
        errors
    end
  end

  defp validate_connection(errors, config) do
    heartbeat = get(config, [:connection, :heartbeat_interval])
    reconnect_initial = get(config, [:connection, :reconnect_initial_delay])
    reconnect_max = get(config, [:connection, :reconnect_max_delay])

    errors =
      if is_integer(heartbeat) and heartbeat > 0 do
        errors
      else
        ["connection.heartbeat_interval must be a positive integer" | errors]
      end

    errors =
      if is_integer(reconnect_initial) and reconnect_initial > 0 do
        errors
      else
        ["connection.reconnect_initial_delay must be a positive integer" | errors]
      end

    if is_integer(reconnect_max) and reconnect_max >= reconnect_initial do
      errors
    else
      ["connection.reconnect_max_delay must be >= reconnect_initial_delay" | errors]
    end
  end

  defp validate_pty(errors, config) do
    max_sessions = get(config, [:pty, :max_sessions])
    idle_timeout = get(config, [:pty, :idle_timeout])

    errors =
      if is_integer(max_sessions) and max_sessions > 0 and max_sessions <= 100 do
        errors
      else
        ["pty.max_sessions must be between 1 and 100" | errors]
      end

    if is_integer(idle_timeout) and idle_timeout >= 0 do
      errors
    else
      ["pty.idle_timeout must be a non-negative integer" | errors]
    end
  end

  defp validate_limits(errors, config) do
    max_output_rate = get(config, [:limits, :max_output_rate])
    max_buffer_size = get(config, [:limits, :max_buffer_size])

    errors =
      if is_integer(max_output_rate) and max_output_rate > 0 do
        errors
      else
        ["limits.max_output_rate must be a positive integer" | errors]
      end

    if is_integer(max_buffer_size) and max_buffer_size > 0 do
      errors
    else
      ["limits.max_buffer_size must be a positive integer" | errors]
    end
  end

  defp system_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "unknown"
    end
  end

  defp generate_agent_id do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "agent_#{random}"
  end
end
