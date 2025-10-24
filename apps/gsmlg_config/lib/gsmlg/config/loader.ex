defmodule GSMLG.Config.Loader do
  @moduledoc """
  Layered configuration loader for GSMLG applications.

  Loads configuration from multiple sources in priority order:
  1. Base configuration (base.toml)
  2. Environment-specific configuration (dev.toml, test.toml, prod.toml)
  3. Local overrides (local.toml - gitignored)
  4. Environment variables (GSMLG_* prefix)

  Each layer is deep-merged with the previous layer, with later layers
  taking precedence over earlier ones.
  """

  require GSMLG.Telemetry

  @doc """
  Loads configuration for the given environment.

  ## Options

    * `:env` - The environment to load config for (:dev, :test, :prod). Defaults to Mix.env()
    * `:config_dir` - Directory containing config files. Defaults to "config"
    * `:validate` - Whether to validate config against schema. Defaults to true

  ## Examples

      iex> GSMLG.Config.Loader.load(env: :dev)
      {:ok, %{database: %{username: "gsmlg_dev", ...}, ...}}

  """
  def load(opts \\ []) do
    env = Keyword.get(opts, :env, Mix.env())
    config_dir = Keyword.get(opts, :config_dir, "config")
    validate? = Keyword.get(opts, :validate, true)

    GSMLG.Telemetry.info("Loading configuration", env: env, config_dir: config_dir)

    with {:ok, config} <- load_layers(env, config_dir),
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
  Loads configuration layers and merges them.
  """
  def load_layers(env, config_dir) do
    layers = [
      {:base, Path.join(config_dir, "base.toml"), required: true},
      {:env, Path.join(config_dir, "#{env}.toml"), required: true},
      {:local, Path.join(config_dir, "local.toml"), required: false}
    ]

    result =
      Enum.reduce_while(layers, {:ok, %{}}, fn {layer_name, path, opts}, {:ok, acc} ->
        case load_toml_file(path, opts) do
          {:ok, layer_config} ->
            GSMLG.Telemetry.debug("Loaded config layer",
              layer: layer_name,
              path: path,
              sections: Map.keys(layer_config)
            )

            merged = deep_merge(acc, layer_config)
            {:cont, {:ok, merged}}

          {:error, reason} = error ->
            GSMLG.Telemetry.error("Failed to load config layer",
              layer: layer_name,
              path: path,
              reason: reason
            )

            {:halt, error}
        end
      end)

    result
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
end
