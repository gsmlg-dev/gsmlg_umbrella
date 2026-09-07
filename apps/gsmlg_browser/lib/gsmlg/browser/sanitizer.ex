defmodule GSMLG.Browser.Sanitizer do
  @moduledoc false

  import Ecto.Changeset, only: [validate_change: 3]

  @sensitive_fragments ~w(prompt page cookie token password secret cdp url path cert)

  def validate_metadata(metadata, allowed_keys, max_bytes \\ 16_384)

  def validate_metadata(metadata, allowed_keys, max_bytes) when is_map(metadata) do
    cond do
      not string_keys?(metadata) -> {:error, :invalid_metadata}
      Map.keys(metadata) -- allowed_keys != [] -> sensitive_or_invalid(metadata)
      sensitive?(metadata) -> {:error, :sensitive_metadata}
      not bounded_term?(metadata, max_bytes) -> {:error, :invalid_metadata}
      not bounded_values?(metadata) -> {:error, :invalid_metadata}
      true -> :ok
    end
  end

  def validate_metadata(_metadata, _allowed_keys, _max_bytes), do: {:error, :invalid_metadata}

  def sensitive?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> sensitive_key?(key) or sensitive?(nested) end)
  end

  def sensitive?(value) when is_list(value), do: Enum.any?(value, &sensitive?/1)
  def sensitive?(_value), do: false

  def validate_safe(value, max_bytes \\ 16_384) do
    cond do
      sensitive?(value) -> {:error, :sensitive_metadata}
      not bounded_term?(value, max_bytes) -> {:error, :invalid_metadata}
      not bounded_value?(value) -> {:error, :invalid_metadata}
      true -> :ok
    end
  end

  def validate_changeset(changeset, fields) do
    Enum.reduce(fields, changeset, fn {field, max_bytes}, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        case validate_safe(value, max_bytes) do
          :ok -> []
          {:error, reason} -> [{field, {"contains unsafe metadata", [validation: reason]}}]
        end
      end)
    end)
  end

  defp sensitive_or_invalid(map) do
    if Enum.any?(Map.keys(map), &sensitive_key?/1),
      do: {:error, :sensitive_metadata},
      else: {:error, :invalid_metadata}
  end

  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_fragments, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(_key), do: true

  defp bounded_values?(map) do
    Enum.all?(map, fn {_key, value} -> bounded_value?(value) end)
  end

  defp bounded_value?(value) when is_binary(value), do: byte_size(value) <= 4_096
  defp bounded_value?(value) when is_boolean(value) or is_number(value) or is_nil(value), do: true

  defp bounded_value?(value) when is_list(value),
    do: length(value) <= 64 and Enum.all?(value, &bounded_value?/1)

  defp bounded_value?(value) when is_map(value),
    do: map_size(value) <= 64 and string_keys?(value) and bounded_values?(value)

  defp bounded_value?(_value), do: false

  defp string_keys?(map), do: Enum.all?(Map.keys(map), &is_binary/1)
  defp bounded_term?(term, max_bytes), do: :erlang.external_size(term) <= max_bytes
end
