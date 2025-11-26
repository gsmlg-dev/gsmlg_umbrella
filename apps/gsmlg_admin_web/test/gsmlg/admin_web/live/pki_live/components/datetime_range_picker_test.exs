defmodule GSMLG.AdminWeb.PKILive.Components.DateTimeRangePickerTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.PKILive.Components.DateTimeRangePicker

  describe "format_datetime_local/1" do
    test "formats DateTime to datetime-local format" do
      dt = ~U[2025-11-25 14:30:45Z]

      result = DateTimeRangePicker.format_datetime_local(dt)

      assert result == "2025-11-25T14:30:45"
    end

    test "removes timezone information" do
      dt = ~U[2025-01-15 09:00:00Z]

      result = DateTimeRangePicker.format_datetime_local(dt)

      refute String.contains?(result, "Z")
      refute String.contains?(result, "+")
      refute String.contains?(result, "-0")
    end

    test "returns empty string for nil" do
      result = DateTimeRangePicker.format_datetime_local(nil)

      assert result == ""
    end

    test "handles ISO8601 string input" do
      iso_string = "2025-11-25T14:30:45Z"

      result = DateTimeRangePicker.format_datetime_local(iso_string)

      assert result == "2025-11-25T14:30:45"
    end

    test "returns input string for invalid format" do
      invalid = "not a valid datetime"

      result = DateTimeRangePicker.format_datetime_local(invalid)

      assert result == invalid
    end
  end

  describe "format_duration/2" do
    test "formats duration in years, months, and days" do
      start_dt = ~U[2025-01-01 00:00:00Z]
      end_dt = ~U[2035-03-16 00:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      assert result =~ "10 years"
      assert result =~ "months"
      assert result =~ "days"
    end

    test "formats duration with single year (no plural)" do
      start_dt = ~U[2025-01-01 00:00:00Z]
      end_dt = ~U[2026-01-01 00:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      assert result =~ "1 year"
      refute result =~ "1 years"
    end

    test "omits zero values from duration" do
      start_dt = ~U[2025-01-01 00:00:00Z]
      end_dt = ~U[2026-01-01 00:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      # Should only show "1 year" without months/days if they are 0
      assert result == "1 year"
    end

    test "handles duration less than 1 day" do
      start_dt = ~U[2025-01-01 10:00:00Z]
      end_dt = ~U[2025-01-01 14:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      assert result == "less than 1 day"
    end

    test "returns error message when end is before start" do
      start_dt = ~U[2035-01-01 00:00:00Z]
      end_dt = ~U[2025-01-01 00:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      assert result == "Invalid range (end before start)"
    end

    test "returns empty string for nil inputs" do
      result = DateTimeRangePicker.format_duration(nil, nil)

      assert result == ""
    end

    test "calculates 10 year duration accurately" do
      start_dt = ~U[2025-01-01 00:00:00Z]
      end_dt = ~U[2035-01-01 00:00:00Z]

      result = DateTimeRangePicker.format_duration(start_dt, end_dt)

      assert result =~ "10 years"
    end
  end

  describe "parse_datetime_local/1" do
    test "parses valid datetime-local format to DateTime" do
      input = "2025-11-25T14:30:45"

      result = DateTimeRangePicker.parse_datetime_local(input)

      assert {:ok, dt} = result
      assert dt.year == 2025
      assert dt.month == 11
      assert dt.day == 25
      assert dt.hour == 14
      assert dt.minute == 30
      assert dt.second == 45
    end

    test "assumes UTC timezone" do
      input = "2025-11-25T14:30:45"

      assert {:ok, dt} = DateTimeRangePicker.parse_datetime_local(input)
      assert dt.time_zone == "Etc/UTC"
    end

    test "returns error for nil input" do
      result = DateTimeRangePicker.parse_datetime_local(nil)

      assert {:error, :invalid_format} = result
    end

    test "returns error for empty string" do
      result = DateTimeRangePicker.parse_datetime_local("")

      assert {:error, :empty} = result
    end

    test "returns error for invalid format" do
      result = DateTimeRangePicker.parse_datetime_local("not a datetime")

      assert {:error, _} = result
    end

    test "handles datetime without seconds" do
      input = "2025-11-25T14:30"

      result = DateTimeRangePicker.parse_datetime_local(input)

      assert {:error, _} = result || match?({:ok, _}, result)
    end
  end
end
