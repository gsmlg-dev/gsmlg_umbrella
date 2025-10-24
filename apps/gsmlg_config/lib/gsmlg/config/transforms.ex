defmodule GSMLG.Config.Transforms do
  @moduledoc """
  Configuration transformation modules.

  Provides composable transforms for configuration data:
  - Type coercion (strings to integers, booleans, etc.)
  - Interpolation (resolve ${VAR} references)
  - Validation (ensure required fields exist)
  """

  defmodule TypeCoercion do
    @moduledoc """
    Transform that coerces configuration values to appropriate types.
    """
    use Toml.Transform

    @doc """
    Coerce port values to integers.
    """
    def transform(:port, value) when is_binary(value) do
      String.to_integer(value)
    end

    def transform(:pool_size, value) when is_binary(value) do
      String.to_integer(value)
    end

    def transform(:log_level, value) when is_binary(value) do
      String.downcase(value)
    end

    def transform(:start, "true"), do: true
    def transform(:start, "false"), do: false
    def transform(:user_register, "true"), do: true
    def transform(:user_register, "false"), do: false
    def transform(:enable_adsense, "true"), do: true
    def transform(:enable_adsense, "false"), do: false
    def transform(:show_icp, "true"), do: true
    def transform(:show_icp, "false"), do: false
    def transform(:server, "true"), do: true
    def transform(:server, "false"), do: false
    def transform(:show_sensitive_data_on_connection_error, "true"), do: true
    def transform(:show_sensitive_data_on_connection_error, "false"), do: false

    def transform(_key, value), do: value
  end

  defmodule Interpolation do
    @moduledoc """
    Transform that interpolates environment variables and runtime values.

    Supports syntax: ${ENV_VAR} or ${ENV_VAR:default_value}
    """
    use Toml.Transform

    @doc """
    Interpolate string values with ${VAR} syntax.
    """
    def transform(_key, value) when is_binary(value) do
      interpolate(value)
    end

    def transform(_key, value), do: value

    defp interpolate(string) do
      Regex.replace(~r/\$\{([^}:]+)(?::([^}]*))?\}/, string, fn _, var, default ->
        System.get_env(var) || default || ""
      end)
    end
  end

  defmodule SecretResolver do
    @moduledoc """
    Transform that resolves secret references.

    Currently supports reading from files with the syntax: SECRET:file:/path/to/secret
    Can be extended to support AWS Secrets Manager, HashiCorp Vault, etc.
    """
    use Toml.Transform

    @doc """
    Resolve secret references.
    """
    def transform(_key, "SECRET:file:" <> path) do
      case File.read(String.trim(path)) do
        {:ok, content} -> String.trim(content)
        {:error, _} -> ""
      end
    end

    def transform(_key, value), do: value
  end

  @doc """
  Get the default transform pipeline.

  Returns a list of transforms that are applied in order:
  1. TypeCoercion - Convert strings to proper types
  2. Interpolation - Resolve ${VAR} references
  3. SecretResolver - Resolve SECRET: references (optional)
  """
  def default_pipeline(include_secrets? \\ false) do
    base = [
      TypeCoercion,
      Interpolation
    ]

    if include_secrets? do
      base ++ [SecretResolver]
    else
      base
    end
  end

  @doc """
  Apply a transform pipeline to configuration data.

  ## Examples

      iex> config = %{web: %{port: "4110"}}
      iex> GSMLG.Config.Transforms.apply_pipeline(config, [TypeCoercion])
      %{web: %{port: 4110}}

  """
  def apply_pipeline(config, transforms) when is_list(transforms) do
    # Note: Toml.Transform expects to work during decoding
    # For post-processing, we need to walk the config tree
    walk_config(config, transforms)
  end

  defp walk_config(config, transforms) when is_map(config) do
    Map.new(config, fn {key, value} ->
      transformed_value = walk_config(value, transforms)
      final_value = apply_transforms(key, transformed_value, transforms)
      {key, final_value}
    end)
  end

  defp walk_config(value, _transforms), do: value

  defp apply_transforms(key, value, transforms) do
    Enum.reduce(transforms, value, fn transform_module, acc ->
      if function_exported?(transform_module, :transform, 2) do
        transform_module.transform(key, acc)
      else
        acc
      end
    end)
  end
end
