defmodule GSMLG.BrowserAgent.Action do
  @moduledoc "Strict decoder for the first-version structured browser actions."

  alias GSMLG.BrowserAgent.{Locator, Postcondition}

  @enforce_keys [:action_id, :session_id, :type, :timeout_ms]
  defstruct action_id: nil,
            session_id: nil,
            expected_revision: nil,
            type: nil,
            locator: nil,
            input: nil,
            timeout_ms: nil,
            preconditions: [],
            postconditions: []

  @types ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download)
  @base_fields ~w(action_id session_id expected_revision type timeout_ms preconditions postconditions postcondition)

  @type t :: %__MODULE__{}

  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, :action_not_allowed}
  def decode(action, opts \\ [])

  def decode(action, opts) when is_map(action) do
    with {:ok, type} <- action_type(action),
         :ok <- validate_base(action),
         {:ok, locator, input, extra_fields} <- decode_input(type, action, opts),
         :ok <- exact_fields(action, @base_fields ++ extra_fields),
         {:ok, preconditions} <- decode_conditions(Map.get(action, "preconditions", []), opts),
         {:ok, postconditions} <- decode_postconditions(action, opts) do
      {:ok,
       %__MODULE__{
         action_id: action["action_id"],
         session_id: action["session_id"],
         expected_revision: action["expected_revision"],
         type: type_atom(type),
         locator: locator,
         input: input,
         preconditions: preconditions,
         postconditions: postconditions,
         timeout_ms: action["timeout_ms"]
       }}
    else
      _invalid -> {:error, :action_not_allowed}
    end
  end

  def decode(_action, _opts), do: {:error, :action_not_allowed}

  defp action_type(%{"type" => type}) when type in @types, do: {:ok, type}
  defp action_type(_action), do: {:error, :invalid_type}

  defp validate_base(action) do
    if valid_id?(action["action_id"]) and valid_id?(action["session_id"]) and
         (is_nil(action["expected_revision"]) or
            (is_integer(action["expected_revision"]) and action["expected_revision"] >= 0)) and
         is_integer(action["timeout_ms"]) and action["timeout_ms"] in 1..120_000,
       do: :ok,
       else: {:error, :invalid_base}
  end

  defp decode_input("navigate", %{"url" => url}, _opts) when is_binary(url),
    do: {:ok, nil, %{"url" => url}, ["url"]}

  defp decode_input(type, %{"locator" => raw}, opts)
       when type in ~w(click focus wait_for extract download) do
    with {:ok, locator} <- Locator.decode(raw, opts) do
      {:ok, locator, nil, ["locator"]}
    end
  end

  defp decode_input(type, %{"locator" => raw, "text" => text}, opts)
       when type in ~w(fill insert_text) and is_binary(text) and byte_size(text) <= 65_536 do
    with {:ok, locator} <- Locator.decode(raw, opts) do
      {:ok, locator, %{"text" => text}, ["locator", "text"]}
    end
  end

  defp decode_input("press_key", %{"key" => key}, _opts)
       when is_binary(key) and byte_size(key) in 1..64,
       do: {:ok, nil, %{"key" => key}, ["key"]}

  defp decode_input("select_option", %{"locator" => raw, "value" => value}, opts)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    with {:ok, locator} <- Locator.decode(raw, opts) do
      {:ok, locator, %{"value" => value}, ["locator", "value"]}
    end
  end

  defp decode_input("scroll", %{"delta_x" => x, "delta_y" => y}, _opts)
       when is_integer(x) and is_integer(y) and x in -100_000..100_000 and
              y in -100_000..100_000,
       do: {:ok, nil, %{"delta_x" => x, "delta_y" => y}, ["delta_x", "delta_y"]}

  defp decode_input("screenshot", _action, _opts), do: {:ok, nil, nil, []}
  defp decode_input(_type, _action, _opts), do: {:error, :invalid_input}

  defp decode_postconditions(%{"postconditions" => _many, "postcondition" => _one}, _opts),
    do: {:error, :ambiguous_postcondition}

  defp decode_postconditions(%{"postconditions" => conditions}, opts),
    do: decode_conditions(conditions, opts)

  defp decode_postconditions(%{"postcondition" => condition}, opts) do
    with {:ok, decoded} <- Postcondition.decode(condition, opts), do: {:ok, [decoded]}
  end

  defp decode_postconditions(_action, _opts), do: {:ok, []}

  defp decode_conditions(conditions, opts) when is_list(conditions) and length(conditions) <= 8 do
    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, decoded} ->
      case Postcondition.decode(condition, opts) do
        {:ok, item} -> {:cont, {:ok, [item | decoded]}}
        {:error, _reason} -> {:halt, {:error, :invalid_condition}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_conditions(_conditions, _opts), do: {:error, :invalid_conditions}

  defp exact_fields(action, fields) do
    if Map.keys(action) -- fields == [],
      do: :ok,
      else: {:error, :unknown_field}
  end

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..200

  defp type_atom("navigate"), do: :navigate
  defp type_atom("click"), do: :click
  defp type_atom("focus"), do: :focus
  defp type_atom("fill"), do: :fill
  defp type_atom("insert_text"), do: :insert_text
  defp type_atom("press_key"), do: :press_key
  defp type_atom("select_option"), do: :select_option
  defp type_atom("scroll"), do: :scroll
  defp type_atom("wait_for"), do: :wait_for
  defp type_atom("extract"), do: :extract
  defp type_atom("screenshot"), do: :screenshot
  defp type_atom("download"), do: :download
end
