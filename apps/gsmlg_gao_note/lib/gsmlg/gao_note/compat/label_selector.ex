defmodule GSMLG.GaoNote.Compat.LabelSelector do
  @moduledoc """
  Agent Note selectors and typed value comparisons.

  Regex matching uses bounded OTP PCRE matching, rejecting obvious constructs
  unsupported by Rust regex. This covers the reference contract vectors, but is
  not full Rust regex syntax or complexity parity (Unicode classes and character
  class set operations can differ; exceeding PCRE match limits returns false).
  """
  @operators [">=", "<=", "!=", "^=", "$=", "~=", "=", ">", "<"]
  @exact_error "malformed exact label selector"
  @max_u64 18_446_744_073_709_551_615
  @date_source "([+-][0-9]+|[0-9]{1,4})-\\s*([0-9]{1,2})-\\s*([0-9]{1,2})"
  @date_pattern Regex.compile!("\\A" <> @date_source <> "\\z", "u")
  @datetime_pattern Regex.compile!("\\A(" <> @date_source <> ")(?:T|\\s*)(.+)\\z", "u")

  def parse(input) when is_binary(input) do
    input
    |> String.split("&")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn term, {:ok, selectors} ->
      case parse_term(term) do
        {:ok, selector} -> {:cont, {:ok, [selector | selectors]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selectors} -> {:ok, Enum.reverse(selectors)}
      error -> error
    end
  end

  def parse(_), do: {:error, "label selector must be a string"}

  def matches?(%{key: key}, %{key: other}) when key != other, do: false
  def matches?(_label, %{value: nil}), do: true

  def matches?(%{value: left} = label, %{operator: operator, value: right}) do
    compare(Map.get(label, :value_type, "text"), left, operator, right)
  end

  def matches_all?(labels, selectors) do
    Enum.all?(selectors, fn selector -> Enum.any?(labels, &matches?(&1, selector)) end)
  end

  def valid_value?(type, value) when is_binary(value),
    do: match?({:ok, _}, comparable(type, String.trim(value)))

  def valid_value?(_type, _value), do: false

  defp parse_term("~" <> encoded) do
    with [key, value] <- String.split(encoded, "==", parts: 2),
         {:ok, key} when key != "" <- decode_exact(key),
         {:ok, value} <- decode_exact(value) do
      {:ok, %{key: key, value: value, operator: "=="}}
    else
      _error -> {:error, @exact_error}
    end
  end

  defp parse_term(term) do
    operator =
      @operators
      |> Enum.flat_map(fn token ->
        case :binary.match(term, token) do
          {index, size} -> [{index, -size, token}]
          :nomatch -> []
        end
      end)
      |> Enum.min(fn -> nil end)

    case operator do
      {index, negative_size, token} ->
        key = term |> binary_part(0, index) |> String.trim()

        if key == "" do
          {:ok, %{key: term, value: nil, operator: "="}}
        else
          value =
            binary_part(term, index - negative_size, byte_size(term) - index + negative_size)

          {:ok, %{key: key, value: String.trim(value), operator: token}}
        end

      nil ->
        {:ok, %{key: term, value: nil, operator: "="}}
    end
  end

  defp decode_exact(component) do
    with {:ok, decoded} <- decode_bytes(component, []) do
      if String.valid?(decoded), do: {:ok, decoded}, else: {:error, @exact_error}
    end
  end

  defp decode_bytes("", bytes), do: {:ok, bytes |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode_bytes(<<"%", a, b, rest::binary>>, bytes)
       when (a in ?0..?9 or a in ?a..?f or a in ?A..?F) and
              (b in ?0..?9 or b in ?a..?f or b in ?A..?F) do
    case Integer.parse(<<a, b>>, 16) do
      {byte, ""} when byte >= 0 and byte <= 255 -> decode_bytes(rest, [<<byte>> | bytes])
      _error -> {:error, @exact_error}
    end
  end

  defp decode_bytes("%" <> _rest, _bytes), do: {:error, @exact_error}
  defp decode_bytes(<<byte, rest::binary>>, bytes), do: decode_bytes(rest, [<<byte>> | bytes])

  defp compare(_type, left, "==", right), do: left == right

  defp compare(_type, left, "^=", right),
    do: String.starts_with?(String.downcase(left), String.downcase(right))

  defp compare(_type, left, "$=", right),
    do: String.ends_with?(String.downcase(left), String.downcase(right))

  defp compare(_type, left, "~=", right), do: regex_matches?(left, right)

  defp compare(type, left, operator, right) do
    with {:ok, left} <- comparable(type, String.trim(left)),
         {:ok, right} <- comparable(type, String.trim(right)) do
      ordering =
        cond do
          left < right -> :lt
          left > right -> :gt
          true -> :eq
        end

      compare_ordering(ordering, operator)
    else
      _error -> false
    end
  end

  defp compare_ordering(ordering, "="), do: ordering == :eq
  defp compare_ordering(ordering, "!="), do: ordering != :eq
  defp compare_ordering(ordering, ">"), do: ordering == :gt
  defp compare_ordering(ordering, ">="), do: ordering != :lt
  defp compare_ordering(ordering, "<"), do: ordering == :lt
  defp compare_ordering(ordering, "<="), do: ordering != :gt

  defp comparable(type, value) when type in [nil, "", "text", :text], do: {:ok, value}

  defp comparable(type, value) when type in ["number", :number] do
    value =
      case value do
        "." <> _ -> "0" <> value
        "-." <> tail -> "-0." <> tail
        "+." <> tail -> "+0." <> tail
        _ -> value
      end

    value = Regex.replace(~r/\.([eE]|$)/, value, ".0\\1")

    case Float.parse(value) do
      {number, ""} ->
        # Rust's f64::total_cmp distinguishes negative and positive zero.
        zero_sign = if number == 0 and String.starts_with?(value, "-"), do: -1, else: 0
        {:ok, {number, zero_sign}}

      _error ->
        :error
    end
  end

  defp comparable(type, value) when type in ["version", :version] do
    parts = value |> String.trim_leading("v") |> String.split(".")

    if Enum.all?(parts, &Regex.match?(~r/\A[0-9]+\z/, &1)) do
      numbers = Enum.map(parts, &String.to_integer/1)

      if Enum.all?(numbers, &(&1 <= @max_u64)) do
        {:ok, numbers |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()}
      else
        :error
      end
    else
      :error
    end
  end

  defp comparable(type, value) when type in ["date", :date], do: parse_date(value)

  defp comparable(type, value) when type in ["datetime", "date-time", :datetime] do
    with [date, _year, _month, _day, time] <-
           Regex.run(@datetime_pattern, value, capture: :all_but_first),
         {:ok, date} <- parse_date(date),
         {:ok, time} <- parse_time(time) do
      {:ok, {date, time}}
    else
      _error -> :error
    end
  end

  defp comparable(type, value) when type in ["time", :time], do: parse_time(value)
  defp comparable(_type, _value), do: :error

  defp parse_date(value) do
    case Regex.run(@date_pattern, value, capture: :all_but_first) do
      [year, month, day] ->
        {year, month, day} =
          {String.to_integer(year), String.to_integer(month), String.to_integer(day)}

        if year >= -262_143 and year <= 262_142 and Calendar.ISO.valid_date?(year, month, day) do
          {:ok, {year, month, day}}
        else
          :error
        end

      nil ->
        :error
    end
  end

  defp parse_time(value) do
    case Regex.run(~r/\A\s*([0-9]{1,2}):\s*([0-9]{1,2})(?::\s*([0-9]{1,2}))?\z/u, value,
           capture: :all_but_first
         ) do
      [hour, minute | seconds] ->
        second =
          case seconds do
            [second] when second != "" -> String.to_integer(second)
            _ -> 0
          end

        {hour, minute} = {String.to_integer(hour), String.to_integer(minute)}

        if hour < 24 and minute < 60 and second <= 60 do
          {:ok, {hour, minute, second}}
        else
          :error
        end

      nil ->
        :error
    end
  end

  defp regex_matches?(left, pattern) do
    with true <- supported_regex?(pattern, false),
         {:ok, compiled} <- :re.compile(pattern, [:unicode, :ucp, :caseless, :dollar_endonly]) do
      :re.run(left, compiled, [
        {:capture, :none},
        {:match_limit, 100_000},
        {:match_limit_recursion, 10_000},
        :report_errors
      ]) == :match
    else
      _error -> false
    end
  end

  defp supported_regex?("", _class), do: true

  defp supported_regex?(<<"\\", byte, _rest::binary>>, _class)
       when byte in ?1..?9 or byte in [?g, ?k, ?K, ?R, ?C, ?X, ?Q, ?E],
       do: false

  defp supported_regex?(<<"\\", _byte, rest::binary>>, class), do: supported_regex?(rest, class)
  defp supported_regex?("[" <> rest, _class), do: supported_regex?(rest, true)
  defp supported_regex?("]" <> rest, _class), do: supported_regex?(rest, false)
  defp supported_regex?("(*" <> _rest, false), do: false

  defp supported_regex?("(?" <> rest, false) do
    if String.starts_with?(rest, ["=", "!", "<=", "<!", ">", "P=", "(", "|", "#", "R", "&"]) or
         Regex.match?(~r/\A[+-]?[0-9]/, rest) do
      false
    else
      supported_regex?(rest, false)
    end
  end

  defp supported_regex?(<<_byte, rest::binary>>, class), do: supported_regex?(rest, class)
end
