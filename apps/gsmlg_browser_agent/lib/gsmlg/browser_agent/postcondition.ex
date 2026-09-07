defmodule GSMLG.BrowserAgent.Postcondition do
  @moduledoc "Finite, observation-based browser action postconditions."

  alias GSMLG.BrowserAgent.Locator

  @enforce_keys [:type]
  defstruct [:type, :value, :locator]

  @type t :: %__MODULE__{}

  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, :postcondition_not_allowed}
  def decode(condition, opts \\ [])

  def decode(%{"type" => type, "value" => value} = condition, _opts)
      when type in ["url_is", "origin_is", "title_contains"] and map_size(condition) == 2 and
             is_binary(value) and byte_size(value) in 1..2_048 do
    {:ok, %__MODULE__{type: String.to_existing_atom(type), value: value}}
  end

  def decode(%{"type" => type, "locator" => locator} = condition, opts)
      when type in ["node_present", "node_absent"] and map_size(condition) == 2 do
    case Locator.decode(locator, opts) do
      {:ok, decoded} ->
        {:ok, %__MODULE__{type: String.to_existing_atom(type), locator: decoded}}

      {:error, _reason} ->
        {:error, :postcondition_not_allowed}
    end
  end

  def decode(_condition, _opts), do: {:error, :postcondition_not_allowed}

  @spec verify(t() | nil, map()) :: :ok | {:error, :action_postcondition_failed}
  def verify(nil, _observation), do: :ok

  def verify(%__MODULE__{type: :url_is, value: value}, observation),
    do: result(observation["url"] == value)

  def verify(%__MODULE__{type: :origin_is, value: value}, observation),
    do: result(observation["origin"] == value)

  def verify(%__MODULE__{type: :title_contains, value: value}, observation) do
    result(is_binary(observation["title"]) and String.contains?(observation["title"], value))
  end

  def verify(%__MODULE__{type: :node_present, locator: locator}, observation),
    do: result(match?({:ok, _node}, Locator.find(observation, locator)))

  def verify(%__MODULE__{type: :node_absent, locator: locator}, observation),
    do: result(match?({:error, :action_target_not_found}, Locator.find(observation, locator)))

  @spec verify_all([t()], map()) :: :ok | {:error, :action_postcondition_failed}
  def verify_all(conditions, observation) when is_list(conditions) do
    Enum.reduce_while(conditions, :ok, fn condition, :ok ->
      case verify(condition, observation) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp result(true), do: :ok
  defp result(false), do: {:error, :action_postcondition_failed}
end
