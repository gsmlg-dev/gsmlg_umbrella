defmodule GSMLG.BrowserAgent.Policy do
  @moduledoc "Provider-neutral constrained model policy validator."

  alias GSMLG.BrowserAgent.{Locator, OriginPolicy}

  @allowed_types ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download)
  @locator_types ~w(click focus fill insert_text select_option wait_for extract download)
  @simple_locator_types @locator_types -- ~w(fill insert_text select_option)

  @callback decide(map(), map()) :: {:ok, map()} | {:error, atom()}

  def validate_decision(decision, context) when is_map(decision) and is_map(context) do
    type = decision["type"]
    allowed = Map.get(context, :allowed_actions, @allowed_types)

    with true <- type in @allowed_types and type in allowed,
         :ok <- validate_revision(decision, context),
         :ok <- validate_shape(type, decision),
         :ok <- validate_target(type, decision, context) do
      {:ok, decision}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :policy_action_not_allowed}
      _invalid -> {:error, :policy_action_not_allowed}
    end
  end

  def validate_decision(_decision, _context), do: {:error, :policy_action_not_allowed}

  def validate_observation(observation, context) when is_map(observation) and is_map(context) do
    max_bytes = Map.get(context, :max_observation_bytes, 1_048_576)

    case safe_size(observation) do
      size when is_integer(size) and is_integer(max_bytes) and size <= max_bytes -> :ok
      _oversized_or_invalid -> {:error, :observation_too_large}
    end
  end

  def validate_observation(_observation, _context), do: {:error, :invalid_observation}

  defp validate_revision(decision, %{revision: revision}) when is_integer(revision) do
    if decision["expected_revision"] == revision,
      do: :ok,
      else: {:error, :stale_observation}
  end

  defp validate_revision(_decision, _context), do: {:error, :stale_observation}

  defp validate_shape("navigate", decision),
    do: exact_keys(decision, ~w(type expected_revision url))

  defp validate_shape(type, decision) when type in ~w(click focus wait_for extract download),
    do: exact_keys(decision, ~w(type expected_revision locator))

  defp validate_shape(type, decision) when type in ~w(fill insert_text),
    do: exact_keys(decision, ~w(type expected_revision locator text))

  defp validate_shape("press_key", decision),
    do: exact_keys(decision, ~w(type expected_revision key))

  defp validate_shape("select_option", decision),
    do: exact_keys(decision, ~w(type expected_revision locator value))

  defp validate_shape("scroll", decision),
    do: exact_keys(decision, ~w(type expected_revision delta_x delta_y))

  defp validate_shape("screenshot", decision),
    do: exact_keys(decision, ~w(type expected_revision))

  defp validate_shape(_type, _decision), do: {:error, :policy_action_not_allowed}

  defp validate_target("navigate", %{"url" => url}, context) when is_binary(url) do
    with {:ok, origin} <- OriginPolicy.origin(url),
         true <- origin in Map.get(context, :allowed_origins, []) do
      :ok
    else
      _not_allowed -> {:error, :navigation_not_allowed}
    end
  end

  defp validate_target(type, decision, context) when type in ~w(fill insert_text) do
    if is_binary(decision["text"]) and byte_size(decision["text"]) <= 65_536,
      do: validate_locator(decision["locator"], context),
      else: {:error, :policy_action_not_allowed}
  end

  defp validate_target("select_option", decision, context) do
    if is_binary(decision["value"]) and byte_size(decision["value"]) in 1..1_024,
      do: validate_locator(decision["locator"], context),
      else: {:error, :policy_action_not_allowed}
  end

  defp validate_target(type, %{"locator" => locator}, context)
       when type in @simple_locator_types,
       do: validate_locator(locator, context)

  defp validate_target("press_key", %{"key" => key}, _context)
       when is_binary(key) and byte_size(key) in 1..64,
       do: :ok

  defp validate_target("scroll", %{"delta_x" => x, "delta_y" => y}, _context)
       when is_integer(x) and is_integer(y) and x in -100_000..100_000 and
              y in -100_000..100_000,
       do: :ok

  defp validate_target("screenshot", _decision, _context), do: :ok
  defp validate_target(_type, _decision, _context), do: {:error, :policy_action_not_allowed}

  defp validate_locator(locator, context) do
    case Locator.decode(locator,
           allow_css_locator: Map.get(context, :allow_css_locator, false)
         ) do
      {:ok, _locator} -> :ok
      {:error, _reason} -> {:error, :locator_not_allowed}
    end
  end

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :policy_action_not_allowed}
  end

  defp safe_size(value) do
    value |> JSON.encode!() |> byte_size()
  rescue
    _exception -> nil
  end
end
