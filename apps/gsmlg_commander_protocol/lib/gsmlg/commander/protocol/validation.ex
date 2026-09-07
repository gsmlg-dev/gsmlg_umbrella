defmodule GSMLG.Commander.Protocol.Validation do
  @moduledoc false

  alias GSMLG.Commander.Protocol.Constants
  alias GSMLG.Commander.Protocol.Error

  @protocol_version Constants.protocol_version()
  @browser_control_id Constants.browser_control_id()
  @browser_control_version Constants.browser_control_version()
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @versioned_string ~r{/v[1-9][0-9]*\z}
  @sha256 ~r/\A[0-9a-f]{64}\z/

  def fields(map, required, optional \\ []) do
    allowed = required ++ optional
    keys = Map.keys(map)
    missing = required -- keys
    unknown = keys -- allowed

    cond do
      missing != [] ->
        error("validation", "missing_field", %{"fields" => Enum.sort(missing)})

      unknown != [] ->
        error("validation", "unknown_fields", %{"fields" => Enum.sort(unknown)})

      true ->
        :ok
    end
  end

  def protocol_version(@protocol_version), do: :ok

  def protocol_version(_version) do
    error("protocol", "incompatible_protocol_version", %{
      "supported" => [Constants.protocol_version()]
    })
  end

  def browser_capability(@browser_control_id, @browser_control_version),
    do: :ok

  def browser_capability(id, _version) when id != @browser_control_id do
    error("protocol", "unknown_capability", %{"supported" => [Constants.browser_control_id()]})
  end

  def browser_capability(_id, _version) do
    error("protocol", "unknown_capability_version", %{
      "capability" => Constants.browser_control_id(),
      "supported" => [Constants.browser_control_version()]
    })
  end

  def capability(id, version) do
    case Constants.capability_versions() do
      %{^id => ^version} ->
        :ok

      %{^id => supported} ->
        error("protocol", "unknown_capability_version", %{
          "capability" => id,
          "supported" => [supported]
        })

      supported ->
        error("protocol", "unknown_capability", %{"supported" => Map.keys(supported)})
    end
  end

  def nonempty_string(value, field) when is_binary(value) and value != "" do
    cond do
      not String.valid?(value) -> invalid("invalid_utf8", %{"field" => field})
      String.trim(value) == "" -> invalid("invalid_string", %{"field" => field})
      true -> :ok
    end
  end

  def nonempty_string(_value, field), do: invalid("invalid_string", %{"field" => field})

  def optional_nonempty_string(nil, _field), do: :ok
  def optional_nonempty_string(value, field), do: nonempty_string(value, field)

  def boolean(value, _field) when is_boolean(value), do: :ok
  def boolean(_value, field), do: invalid("invalid_boolean", %{"field" => field})

  def uuid(value, _field) when is_binary(value) do
    if Regex.match?(@uuid, value), do: :ok, else: invalid("invalid_uuid", %{})
  end

  def uuid(_value, field), do: invalid("invalid_uuid", %{"field" => field})

  def timestamp(value, _field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      {:error, _reason} -> invalid("invalid_timestamp", %{})
    end
  end

  def timestamp(_value, field), do: invalid("invalid_timestamp", %{"field" => field})

  def future_timestamp(value, field, opts) do
    with :ok <- timestamp(value, field),
         {:ok, deadline, _offset} <- DateTime.from_iso8601(value),
         {:ok, now} <- now(opts) do
      if DateTime.compare(deadline, now) == :gt,
        do: :ok,
        else: invalid("expired_deadline", %{"field" => field})
    end
  end

  def positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  def positive_integer(_value, field) do
    invalid("invalid_positive_integer", %{"field" => field})
  end

  def nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  def nonnegative_integer(_value, field) do
    invalid("invalid_nonnegative_integer", %{"field" => field})
  end

  def bounded_string(value, field, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 do
    with :ok <- nonempty_string(value, field) do
      if byte_size(value) <= max_bytes,
        do: :ok,
        else: invalid("string_too_large", %{"field" => field, "max_bytes" => max_bytes})
    end
  end

  def bounded_string(_value, field, _max_bytes),
    do: invalid("invalid_string", %{"field" => field})

  def sha256(value, _field) when is_binary(value) do
    if Regex.match?(@sha256, value), do: :ok, else: invalid("invalid_sha256", %{})
  end

  def sha256(_value, field), do: invalid("invalid_sha256", %{"field" => field})

  def one_of(value, allowed, field) when is_list(allowed) do
    if value in allowed,
      do: :ok,
      else: invalid("invalid_value", %{"field" => field, "allowed" => allowed})
  end

  def wire_map(value, field) when is_map(value) do
    with :ok <- string_keys(value, field), do: wire_value(value, field)
  end

  def wire_map(_value, field), do: invalid("invalid_map", %{"field" => field})

  def string_list(value, field) when is_list(value) do
    with :ok <- each(value, &nonempty_string(&1, field)),
         :ok <- unique(value, field) do
      :ok
    end
  end

  def string_list(_value, field), do: invalid("invalid_list", %{"field" => field})

  def operations(capability_id, value) do
    with :ok <- string_list(value, "operations") do
      case value -- (Constants.operations(capability_id) || []) do
        [] -> :ok
        _unknown -> invalid("unknown_operation", %{"field" => "operations"})
      end
    end
  end

  def operation(capability_id, value) do
    with :ok <- nonempty_string(value, "operation") do
      if value in (Constants.operations(capability_id) || []),
        do: :ok,
        else: invalid("unknown_operation", %{"field" => "operation"})
    end
  end

  def limits(value) when is_map(value) do
    with :ok <- string_keys(value, "limits") do
      each(value, fn {_key, limit} -> nonnegative_integer(limit, "limits") end)
    end
  end

  def limits(_value), do: invalid("invalid_map", %{"field" => "limits"})

  def workflows(value) do
    with :ok <- string_list(value, "workflows") do
      each(value, fn workflow ->
        if Regex.match?(@versioned_string, workflow),
          do: :ok,
          else: invalid("invalid_versioned_string", %{"field" => "workflows"})
      end)
    end
  end

  def encoded_size(value) do
    try do
      {:ok, value |> JSON.encode!() |> byte_size()}
    rescue
      Protocol.UndefinedError -> invalid("invalid_wire_value", %{})
      ArgumentError -> invalid("invalid_wire_value", %{})
      ErlangError -> invalid("invalid_utf8", %{})
    end
  end

  def error(class, code, details), do: {:error, Error.new(class, code, details)}
  def invalid(code, details), do: error("validation", code, details)

  defp string_keys(map, field) do
    keys = Map.keys(map)

    cond do
      not Enum.all?(keys, &is_binary/1) -> invalid("non_string_key", %{"field" => field})
      not Enum.all?(keys, &String.valid?/1) -> invalid("invalid_utf8", %{"field" => field})
      true -> :ok
    end
  end

  defp wire_value(value, field) when is_map(value) do
    with :ok <- string_keys(value, field),
         :ok <- each(value, fn {_key, nested} -> wire_value(nested, field) end) do
      :ok
    end
  end

  defp wire_value(value, field) when is_list(value), do: each(value, &wire_value(&1, field))

  defp wire_value(value, field) when is_binary(value) do
    if String.valid?(value), do: :ok, else: invalid("invalid_utf8", %{"field" => field})
  end

  defp wire_value(value, _field) when is_number(value), do: :ok
  defp wire_value(value, _field) when is_boolean(value), do: :ok
  defp wire_value(nil, _field), do: :ok
  defp wire_value(_value, field), do: invalid("invalid_wire_value", %{"field" => field})

  defp unique(values, field) do
    if length(values) == MapSet.size(MapSet.new(values)),
      do: :ok,
      else: invalid("duplicate_value", %{"field" => field})
  end

  defp each(enumerable, validator) do
    Enum.reduce_while(enumerable, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp now(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0) do
      %DateTime{} = now -> {:ok, now}
      now when is_function(now, 0) -> now_value(now)
      _invalid -> invalid("invalid_now", %{})
    end
  end

  defp now_value(fun) do
    case fun.() do
      %DateTime{} = now -> {:ok, now}
      _invalid -> invalid("invalid_now", %{})
    end
  end
end
