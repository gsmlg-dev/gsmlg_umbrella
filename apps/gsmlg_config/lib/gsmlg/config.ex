defmodule GSMLG.Config do
  @moduledoc """
  Configuration accessor for GSMLG applications.

  Configuration is loaded from layered TOML files at runtime via `config/runtime.exs`:
  - `config/base.toml` - Base defaults
  - `config/{env}.toml` - Environment-specific overrides (dev.toml, test.toml, prod.toml)
  - `config/local.toml` - Local overrides (optional, gitignored)
  - `GSMLG_*` environment variables - Runtime overrides

  ## Examples

      # Get entire configuration
      config = GSMLG.Config.config()

      # Get a specific section
      database_config = GSMLG.Config.get(:database)

      # Get a nested value
      hostname = GSMLG.Config.get([:database, :hostname])

      # Reload configuration (development only)
      GSMLG.Config.reload()

  """

  require GSMLG.Telemetry

  @doc """
  Returns the entire configuration map.
  """
  def config do
    case Application.get_env(:gsmlg_config, :loaded_config) do
      nil ->
        GSMLG.Telemetry.warn("Configuration not loaded, returning empty map")
        %{}

      config ->
        config
    end
  end

  @doc """
  Gets a configuration value by key or path.

  ## Examples

      # Get a top-level section
      GSMLG.Config.get(:database)
      #=> %{username: "gsmlg_dev", password: "gsmlg_dev", ...}

      # Get a nested value
      GSMLG.Config.get([:database, :hostname])
      #=> "mariadb-server.gsmlg.net"

      # String keys are converted to atoms
      GSMLG.Config.get("database")
      #=> %{username: "gsmlg_dev", ...}

  """
  def get(name) when is_binary(name) or is_atom(name) do
    config = config()
    name_atom = if is_binary(name), do: String.to_atom(name), else: name

    case Map.get(config, name_atom) do
      nil when is_binary(name) -> Map.get(config, name)
      value -> value
    end
  end

  def get(name_path) when is_list(name_path) do
    get_in(config(), name_path)
  end

  @doc """
  Gets a configuration value with a default.

  ## Examples

      GSMLG.Config.get(:nonexistent, :default_value)
      #=> :default_value

      GSMLG.Config.get([:database, :pool_size], 10)
      #=> 10 (or the configured value if it exists)

  """
  def get(name, default) when is_binary(name) or is_atom(name) do
    case get(name) do
      nil -> default
      value -> value
    end
  end

  def get(name_path, default) when is_list(name_path) do
    case get(name_path) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Reloads configuration from TOML files.

  This is primarily useful during development. In production, configuration
  should be managed through environment variables and requires an application restart.

  Returns `{:ok, config}` on success or `{:error, reason}` on failure.
  """
  def reload do
    GSMLG.Telemetry.info("Reloading configuration")

    case GSMLG.Config.Loader.load(env: Mix.env()) do
      {:ok, config} ->
        Application.put_env(:gsmlg_config, :loaded_config, config)
        GSMLG.Config.Setup.setup(config)

        GSMLG.Telemetry.info("Configuration reloaded successfully",
          sections: Map.keys(config)
        )

        {:ok, config}

      {:error, reason} = error ->
        GSMLG.Telemetry.error("Configuration reload failed", reason: reason)
        error
    end
  end

  @doc """
  Same as `reload/0` but raises on error.
  """
  def reload! do
    case reload() do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "Failed to reload configuration: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the path to the configuration file for the given environment.

  ## Examples

      GSMLG.Config.config_path(:dev)
      #=> "config/dev.toml"

  """
  def config_path(env) do
    Path.join("config", "#{env}.toml")
  end

  @doc """
  Validates the current configuration against the schema.

  Returns `{:ok, config}` if valid or `{:error, reasons}` if invalid.
  """
  def validate do
    config = config()
    GSMLG.Config.Schema.validate(config)
  end

  @doc """
  Same as `validate/0` but raises on error.
  """
  def validate! do
    config = config()
    GSMLG.Config.Schema.validate!(config)
  end
end
