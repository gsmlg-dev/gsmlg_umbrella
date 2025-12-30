defmodule GSMLG.Config.Loader do
  @moduledoc """
  Layered configuration loader for GSMLG applications.

  Loads configuration from multiple sources in priority order:
  1. Custom config file (if specified via --config flag or GSMLG_CONFIG_PATH)
  2. Environment-specific configuration (gsmlg.{env}.toml)
  3. Default configuration (gsmlg.toml)
  4. Environment variables (GSMLG_* prefix)

  Each layer is deep-merged with the previous layer, with later layers
  taking precedence over earlier ones.

  ## Configuration Path Priority

  The configuration file path is determined in the following order:

  1. Command line argument: `--config=/path/to/config.toml` (in production release)
  2. Environment variable: `GSMLG_CONFIG_PATH=/path/to/config.toml`
  3. Loader option: `GSMLG.Config.Loader.load(config_path: "/path/to/config.toml")`
  4. Default: `apps/gsmlg_config/priv/gsmlg.{env}.toml` or `gsmlg.toml`

  ## Usage Examples

      # Development (Mix)
      GSMLG_CONFIG_PATH=/etc/gsmlg/custom.toml mix phx.server

      # Production (Release)
      ./bin/gsmlg_umbrella start --config=/etc/gsmlg/custom.toml

      # Programmatic
      GSMLG.Config.Loader.load(config_path: "/custom/config.toml")

  """

  require GSMLG.Telemetry

  @doc """
  Loads configuration for the given environment.

  ## Options

    * `:env` - The environment to load config for (:dev, :test, :prod). Defaults to Mix.env()
    * `:config_path` - Override path to config file. Takes precedence over default paths.
    * `:config_dir` - Directory containing config files. Defaults to "apps/gsmlg_config/priv"
    * `:validate` - Whether to validate config against schema. Defaults to true

  ## Examples

      iex> GSMLG.Config.Loader.load(env: :dev)
      {:ok, %{database: %{username: "gsmlg_dev", ...}, ...}}

      iex> GSMLG.Config.Loader.load(config_path: "/custom/path/config.toml")
      {:ok, %{...}}

  """
  def load(opts \\ []) do
    env = Keyword.get(opts, :env, get_env())
    config_path = Keyword.get(opts, :config_path) || System.get_env("GSMLG_CONFIG_PATH")
    config_dir = Keyword.get(opts, :config_dir, "apps/gsmlg_config/priv")
    validate? = Keyword.get(opts, :validate, true)

    GSMLG.Telemetry.info("Loading configuration",
      env: env,
      config_dir: config_dir,
      config_path: config_path
    )

    with {:ok, config} <- load_config_file(env, config_dir, config_path),
         {:ok, config} <- apply_env_overrides(config),
         {:ok, config} <- maybe_validate(config, validate?) do
      GSMLG.Telemetry.info("Configuration loaded successfully",
        sections: Map.keys(config),
        env: env
      )

      {:ok, config}
    else
      {:error, reason} = error ->
        GSMLG.Telemetry.error("Configuration loading failed",
          reason: reason,
          env: env
        )

        error
    end
  end

  @doc """
  Same as `load/1` but raises on error.
  """
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "Failed to load configuration: #{inspect(reason)}"
    end
  end

  @doc """
  Loads configuration from a single file.

  Priority order:
  1. Custom config_path if provided
  2. Environment-specific file: gsmlg.{env}.toml
  3. Fallback to gsmlg.toml
  """
  def load_config_file(env, config_dir, custom_path \\ nil) do
    paths =
      if custom_path do
        # If custom path provided, try only that
        [{:custom, custom_path, required: true}]
      else
        # Otherwise try env-specific, then fallback
        [
          {:env, Path.join(config_dir, "gsmlg.#{env}.toml"), required: false},
          {:fallback, Path.join(config_dir, "gsmlg.toml"), required: true}
        ]
      end

    # Try each path until we find one that works
    Enum.reduce_while(paths, {:error, :no_config_found}, fn {type, path, opts}, _acc ->
      required? = Keyword.get(opts, :required, true)

      case load_toml_file(path, opts) do
        {:ok, config} ->
          GSMLG.Telemetry.info("Loaded configuration file",
            type: type,
            path: path,
            sections: Map.keys(config)
          )

          {:halt, {:ok, config}}

        {:error, {:file_not_found, _}} when not required? ->
          GSMLG.Telemetry.debug("Optional config file not found, trying next",
            type: type,
            path: path
          )

          {:cont, {:error, :no_config_found}}

        {:error, reason} = error ->
          GSMLG.Telemetry.error("Failed to load config file",
            type: type,
            path: path,
            reason: reason
          )

          {:halt, error}
      end
    end)
  end

  @doc """
  Loads a single TOML file.

  ## Options

    * `:required` - Whether the file must exist. Defaults to true.

  """
  def load_toml_file(path, opts \\ []) do
    required? = Keyword.get(opts, :required, true)

    cond do
      File.exists?(path) ->
        case Toml.decode_file(path, keys: :atoms) do
          {:ok, config} -> {:ok, config}
          {:error, reason} -> {:error, {:toml_decode_error, path, reason}}
        end

      required? ->
        {:error, {:file_not_found, path}}

      true ->
        {:ok, %{}}
    end
  end

  @doc """
  Applies environment variable overrides to configuration.

  Environment variables with the prefix `GSMLG_` are parsed and merged
  into the configuration. Double underscores represent nested keys.

  ## Examples

      GSMLG_DATABASE__HOSTNAME=db.example.com
      => config[:database][:hostname] = "db.example.com"

      GSMLG_WEB__PORT=8080
      => config[:web][:port] = 8080

  """
  def apply_env_overrides(config) do
    env_config =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "GSMLG_") end)
      |> Enum.map(&parse_env_var/1)
      |> Enum.reduce(%{}, fn {path, value}, acc ->
        put_in_path(acc, path, value)
      end)

    if map_size(env_config) > 0 do
      GSMLG.Telemetry.debug("Applied environment variable overrides",
        count: map_size(env_config)
      )
    end

    {:ok, deep_merge(config, env_config)}
  end

  @doc """
  Deep merges two maps or keyword lists.

  Lists are replaced (not merged). Maps and keyword lists are recursively merged.
  """
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      deep_merge(left_val, right_val)
    end)
  end

  def deep_merge(left, right) when is_list(left) and is_list(right) do
    if Keyword.keyword?(left) and Keyword.keyword?(right) do
      Keyword.merge(left, right, fn _key, left_val, right_val ->
        deep_merge(left_val, right_val)
      end)
    else
      # Non-keyword lists are replaced
      right
    end
  end

  def deep_merge(_left, right), do: right

  # Private functions

  defp parse_env_var({key, value}) do
    # Remove GSMLG_ prefix and split by double underscore
    path =
      key
      |> String.replace_prefix("GSMLG_", "")
      |> String.downcase()
      |> String.split("__")
      |> Enum.map(&String.to_atom/1)

    # Try to coerce the value to appropriate type
    coerced_value = coerce_value(value)

    {path, coerced_value}
  end

  defp coerce_value("true"), do: true
  defp coerce_value("false"), do: false
  defp coerce_value("nil"), do: nil

  defp coerce_value(value) do
    cond do
      # Try integer
      Regex.match?(~r/^-?\d+$/, value) ->
        String.to_integer(value)

      # Try float
      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        String.to_float(value)

      # Keep as string
      true ->
        value
    end
  end

  defp put_in_path(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_in_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_path(nested, rest, value))
  end

  defp maybe_validate(config, false), do: {:ok, config}

  defp maybe_validate(config, true) do
    case GSMLG.Config.Schema.validate(config) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:validation_error, reason}}
    end
  end

  # Get the current environment, works both in Mix and release
  defp get_env do
    cond do
      # Check environment variable first (useful for releases)
      env_str = System.get_env("MIX_ENV") ->
        String.to_atom(env_str)

      # Check if Mix is available (development/test)
      function_exported?(Mix, :env, 0) ->
        Mix.env()

      # Default to :prod for releases
      true ->
        :prod
    end
  end
end
