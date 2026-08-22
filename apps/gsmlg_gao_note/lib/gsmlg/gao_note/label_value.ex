defmodule GSMLG.GaoNote.LabelValue do
  alias GSMLG.GaoNote.LabelSetting

  def normalize(nil), do: ""
  def normalize(value) when is_binary(value), do: String.trim(value)
  def normalize(value), do: value |> to_string() |> String.trim()

  def classify(%LabelSetting{value_type: value_type}, value) do
    value = normalize(value)
    value_type = value_type || "text"

    case value_type do
      "text" -> valid_label()
      "number" -> validate_number_label(value)
      "version" -> validate_version_label(value)
      "date" -> validate_date_label(value)
      "date-time" -> validate_datetime_label(value)
      "time" -> validate_time_label(value)
      "year" -> validate_regex_label(value, ~r/^\d{4}$/, "must be YYYY")
      "year-month" -> validate_regex_label(value, ~r/^\d{4}-(0[1-9]|1[0-2])$/, "must be YYYY-MM")
      "year-season" -> validate_regex_label(value, ~r/^\d{4}-Q[1-4]$/, "must be YYYY-Q1..YYYY-Q4")
      _other -> invalid_label("unsupported value type #{value_type}")
    end
  end

  def validate(%LabelSetting{id: id} = label_setting, value) do
    normalized = normalize(value)

    case classify(label_setting, normalized) do
      {"valid", []} ->
        {:ok, normalized}

      {"invalid", errors} ->
        {:error, {:invalid_label_value, %{label_setting_id: id, errors: errors}}}
    end
  end

  defp validate_number_label(value) do
    case Float.parse(value) do
      {_number, ""} -> valid_label()
      _other -> invalid_label("must be a number")
    end
  end

  defp validate_version_label(value) do
    if Regex.match?(~r/^v?\d+(\.\d+){0,3}([+-][0-9A-Za-z.-]+)?$/, value) do
      valid_label()
    else
      invalid_label("must be a version")
    end
  end

  defp validate_date_label(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> valid_label()
      {:error, _reason} -> invalid_label("must be YYYY-MM-DD")
    end
  end

  defp validate_datetime_label(value) do
    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        valid_label()

      match?({:ok, _datetime}, NaiveDateTime.from_iso8601(value)) ->
        valid_label()

      true ->
        invalid_label("must be ISO8601 date-time")
    end
  end

  defp validate_time_label(value) do
    case Time.from_iso8601(value) do
      {:ok, _time} -> valid_label()
      {:error, _reason} -> invalid_label("must be ISO8601 time")
    end
  end

  defp validate_regex_label(value, regex, message) do
    if Regex.match?(regex, value), do: valid_label(), else: invalid_label(message)
  end

  defp valid_label, do: {"valid", []}
  defp invalid_label(message), do: {"invalid", [message]}
end
