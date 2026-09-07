defmodule GSMLG.BrowserAgent.Locator do
  @moduledoc "Finite semantic locator algebra for safe browser actions."

  @enforce_keys [:type, :value]
  defstruct [:type, :value, :name]

  @safe_attributes ~w(aria-controls type)

  @type t :: %__MODULE__{type: atom(), value: String.t(), name: String.t() | nil}

  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, :locator_not_allowed}
  def decode(locator, opts \\ [])

  def decode(%{"node_id" => value} = locator, _opts) when map_size(locator) == 1,
    do: locator(:node_id, value)

  def decode(%{"role" => role} = locator, _opts) when map_size(locator) in [1, 2] do
    case Map.keys(locator) -- ["role", "accessible_name"] do
      [] -> locator(:role, role, Map.get(locator, "accessible_name"))
      _unknown -> {:error, :locator_not_allowed}
    end
  end

  def decode(%{"label" => value} = locator, _opts) when map_size(locator) == 1,
    do: locator(:label, value)

  def decode(%{"placeholder" => value} = locator, _opts) when map_size(locator) == 1,
    do: locator(:placeholder, value)

  def decode(%{"text" => value} = locator, _opts) when map_size(locator) == 1,
    do: locator(:text, value)

  def decode(%{"attribute" => %{"name" => name, "value" => value}} = locator, _opts)
      when map_size(locator) == 1 and name in @safe_attributes,
      do: locator(:attribute, value, name)

  def decode(%{"css" => value} = locator, opts) when map_size(locator) == 1 do
    if Keyword.get(opts, :allow_css_locator, false), do: locator(:css, value), else: error()
  end

  def decode(_locator, _opts), do: error()

  @spec find(map(), t()) :: {:ok, map()} | {:error, :action_target_not_found}
  def find(%{"semantic_tree" => nodes}, %__MODULE__{} = locator) when is_list(nodes) do
    case Enum.find(nodes, &matches?(&1, locator)) do
      nil -> {:error, :action_target_not_found}
      node -> {:ok, node}
    end
  end

  def find(_observation, _locator), do: {:error, :action_target_not_found}

  defp matches?(node, %__MODULE__{type: :node_id, value: value}),
    do: node["node_id"] == value

  defp matches?(node, %__MODULE__{type: :role, value: role, name: nil}),
    do: node["role"] == role

  defp matches?(node, %__MODULE__{type: :role, value: role, name: name}),
    do: node["role"] == role and node["name"] == name

  defp matches?(node, %__MODULE__{type: type, value: value})
       when type in [:label, :placeholder],
       do: node[Atom.to_string(type)] == value

  defp matches?(node, %__MODULE__{type: :text, value: value}) do
    Enum.any?([node["name"], node["value"]], &(is_binary(&1) and String.contains?(&1, value)))
  end

  defp matches?(node, %__MODULE__{type: :attribute, name: name, value: value}),
    do: get_in(node, ["attributes", name]) == value

  defp matches?(_node, %__MODULE__{type: :css}), do: false

  defp locator(type, value, name \\ nil) do
    if valid_value?(value) and (is_nil(name) or valid_value?(name)) do
      {:ok, %__MODULE__{type: type, value: value, name: name}}
    else
      error()
    end
  end

  defp valid_value?(value), do: is_binary(value) and byte_size(value) in 1..512
  defp error, do: {:error, :locator_not_allowed}
end
