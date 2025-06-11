defmodule GSMLG.WebPush.Subscription do
  @type t :: %__MODULE__{
          endpoint: binary(),
          keys: map(),
          expiration_time: integer()
        }

  defstruct [:endpoint, :keys, :expiration_time]

  def new(attrs) do
    struct(__MODULE__, convert_keys(attrs))
  end

  defp convert_keys(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      try do
        Map.put(
          acc,
          convert_key(k),
          convert_val(v)
        )
      rescue
        _e in ArgumentError ->
          raise ArgumentError, "failed to convert key #{inspect(k)} to existing atom"
      end
    end)
  end

  defp convert_key(k) when is_atom(k) do
    k
  end

  defp convert_key(k) when is_binary(k) do
    String.to_atom(k)
  end

  defp convert_val(val) when is_map(val) do
    convert_keys(val)
  end

  defp convert_val(val) do
    val
  end
end
