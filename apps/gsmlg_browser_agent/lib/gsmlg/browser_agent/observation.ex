defmodule GSMLG.BrowserAgent.Observation do
  @moduledoc "Builds bounded, redacted semantic observations from local browser state."

  alias GSMLG.BrowserAgent.OriginPolicy

  @node_fields ~w(node_id backend_node_id role name value state bounds label placeholder attributes depth)
  @control_roles ~w(button checkbox combobox link listbox menuitem radio searchbox slider spinbutton switch tab textbox)
  @sensitive_markers ~w(password passcode secret token otp one-time credit-card cc-number)

  @spec build(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def build(raw, opts) when is_map(raw) do
    with true <- valid_utf8_tree?(raw),
         {:ok, url} <- required_string(raw, "url", 2_048),
         {:ok, origin} <- OriginPolicy.origin(url),
         {:ok, title} <- optional_string(raw, "title", 1_024),
         {:ok, nodes} <- normalize_nodes(Map.get(raw, "nodes", []), opts) do
      observed_at = Keyword.fetch!(opts, :observed_at)

      observation = %{
        "session_id" => Keyword.fetch!(opts, :session_id),
        "lease_id" => Keyword.fetch!(opts, :lease_id),
        "revision" => Keyword.fetch!(opts, :revision),
        "url" => url,
        "origin" => origin,
        "title" => title || "",
        "loading_state" =>
          normalize_enum(raw["loading_state"], ~w(loading interactive complete), "complete"),
        "page_kind" =>
          normalize_enum(raw["page_kind"], ~w(document dialog error unknown), "unknown"),
        "alerts" => normalize_strings(raw["alerts"], 20, 512),
        "visible_controls" => visible_controls(nodes),
        "semantic_tree" => nodes,
        "focused_element" => normalize_focused(raw["focused_element"]),
        "observed_at" => iso8601(observed_at),
        "expires_at" =>
          iso8601(DateTime.add(observed_at, Keyword.fetch!(opts, :ttl_ms), :millisecond))
      }

      fit_to_bytes(observation, Keyword.fetch!(opts, :max_bytes))
    else
      _invalid -> {:error, :invalid_observation}
    end
  end

  def build(_raw, _opts), do: {:error, :invalid_observation}

  defp normalize_nodes(nodes, opts) when is_list(nodes) do
    max_nodes = Keyword.fetch!(opts, :max_nodes)
    max_depth = Keyword.fetch!(opts, :max_depth)

    normalized =
      nodes
      |> Enum.filter(fn node ->
        is_map(node) and Map.get(node, "visible", true) == true and
          is_integer(Map.get(node, "depth", 0)) and Map.get(node, "depth", 0) >= 0 and
          Map.get(node, "depth", 0) <= max_depth
      end)
      |> Enum.take(max_nodes)
      |> Enum.map(&normalize_node/1)

    {:ok, normalized}
  end

  defp normalize_nodes(_nodes, _opts), do: {:error, :invalid_nodes}

  defp normalize_node(node) do
    normalized =
      node
      |> Map.take(@node_fields)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case normalize_node_value(key, value) do
          nil -> acc
          safe -> Map.put(acc, key, safe)
        end
      end)

    if sensitive_node?(node) and Map.has_key?(normalized, "value") do
      Map.put(normalized, "value", "[REDACTED]")
    else
      normalized
    end
  end

  defp normalize_node_value(_key, value) when is_boolean(value) or is_number(value), do: value
  defp normalize_node_value(_key, value) when is_binary(value), do: truncate(value, 1_024)

  defp normalize_node_value("attributes", attributes) when is_map(attributes) do
    attributes
    |> Map.take(~w(data-testid data-test id name aria-label type autocomplete href))
    |> Enum.flat_map(fn
      {"href", value} ->
        case safe_href(value) do
          {:ok, href} -> [{"href", href}]
          :error -> []
        end

      {key, value} ->
        [{key, truncate(to_string(value), 512)}]
    end)
    |> Map.new()
  end

  defp normalize_node_value("state", state) when is_map(state) do
    state
    |> Map.take(~w(checked disabled expanded focused pressed readonly required selected))
    |> Map.filter(fn {_key, value} -> is_boolean(value) or is_binary(value) end)
  end

  defp normalize_node_value("bounds", %{} = bounds) do
    bounds
    |> Map.take(~w(x y width height))
    |> Map.filter(fn {_key, value} -> is_number(value) end)
  end

  defp normalize_node_value(_key, _value), do: nil

  defp safe_href(value) when is_binary(value) and byte_size(value) in 1..2_048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        {:ok, value}

      _unsafe ->
        :error
    end
  end

  defp safe_href(_value), do: :error

  defp sensitive_node?(node) do
    candidates = [
      node["input_type"],
      node["name"],
      node["label"],
      get_in(node, ["attributes", "type"]),
      get_in(node, ["attributes", "autocomplete"])
    ]

    Enum.any?(candidates, fn
      value when is_binary(value) ->
        downcased = String.downcase(value)
        Enum.any?(@sensitive_markers, &String.contains?(downcased, &1))

      _other ->
        false
    end)
  end

  defp visible_controls(nodes) do
    nodes
    |> Enum.filter(&(&1["role"] in @control_roles))
    |> Enum.map(&Map.take(&1, ~w(node_id role name value state label placeholder)))
  end

  defp fit_to_bytes(observation, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    if encoded_size(observation) <= max_bytes do
      {:ok, observation}
    else
      trim_nodes(observation, max_bytes)
    end
  end

  defp fit_to_bytes(_observation, _max_bytes), do: {:error, :invalid_observation_limit}

  defp trim_nodes(%{"semantic_tree" => []} = observation, max_bytes) do
    trimmed = %{observation | "visible_controls" => [], "alerts" => []}

    if encoded_size(trimmed) <= max_bytes,
      do: {:ok, trimmed},
      else: {:error, :observation_too_large}
  end

  defp trim_nodes(observation, max_bytes) do
    nodes = Enum.drop(observation["semantic_tree"], -1)

    trim_nodes(
      %{observation | "semantic_tree" => nodes, "visible_controls" => visible_controls(nodes)},
      max_bytes
    )
  end

  defp required_string(map, key, max) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max ->
        {:ok, value}

      _invalid ->
        {:error, :invalid_string}
    end
  end

  defp optional_string(map, key, max) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= max -> {:ok, value}
      _invalid -> {:error, :invalid_string}
    end
  end

  defp normalize_strings(items, max_items, max_bytes) when is_list(items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.take(max_items)
    |> Enum.map(&truncate(&1, max_bytes))
  end

  defp normalize_strings(_items, _max_items, _max_bytes), do: []

  defp normalize_focused(%{} = node), do: node |> normalize_node() |> Map.drop(["value"])
  defp normalize_focused(_node), do: nil

  defp normalize_enum(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {items, bytes} ->
      grapheme_bytes = byte_size(grapheme)

      if bytes + grapheme_bytes <= max_bytes do
        {:cont, {[grapheme | items], bytes + grapheme_bytes}}
      else
        {:halt, {items, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp valid_utf8_tree?(value) when is_binary(value), do: String.valid?(value)
  defp valid_utf8_tree?(value) when is_map(value), do: Enum.all?(value, &valid_utf8_tree?/1)
  defp valid_utf8_tree?(value) when is_list(value), do: Enum.all?(value, &valid_utf8_tree?/1)
  defp valid_utf8_tree?({key, value}), do: valid_utf8_tree?(key) and valid_utf8_tree?(value)
  defp valid_utf8_tree?(_value), do: true

  defp encoded_size(value), do: value |> JSON.encode!() |> byte_size()

  defp iso8601(%DateTime{} = datetime) do
    microsecond = elem(datetime.microsecond, 0)
    DateTime.to_iso8601(%{datetime | microsecond: {microsecond, 3}})
  end
end
