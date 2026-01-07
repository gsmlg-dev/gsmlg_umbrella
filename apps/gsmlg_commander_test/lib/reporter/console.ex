defmodule GSMLG.CommanderTest.Reporter.Console do
  @moduledoc """
  Console reporter for E2E test results.

  Outputs formatted test results to the console with:
  - Colored pass/fail indicators
  - Timing information
  - Summary statistics
  - Failed test details

  """

  @doc """
  Report test results to the console.
  """
  @spec report([map()], map()) :: :ok
  def report(_results, _summary) do
    # Results are already printed during execution by TestRunner
    # This can be used for additional console output if needed
    :ok
  end

  @doc """
  Print the test run header.
  """
  @spec start_run(map()) :: :ok
  def start_run(config) do
    IO.puts("")
    IO.puts(String.duplicate("=", 60))
    IO.puts("  Commander E2E Test Run")
    IO.puts("  Port: #{config.port}")
    IO.puts("  Started: #{DateTime.utc_now()}")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")
    :ok
  end

  @doc """
  Print a scenario result.
  """
  @spec scenario_result(map()) :: :ok
  def scenario_result(%{scenario: name, result: :passed, duration: duration}) do
    IO.puts("  #{pass_indicator()} #{name} (#{duration}ms)")
    :ok
  end

  def scenario_result(%{scenario: name, result: {:failed, _reason}, duration: duration}) do
    IO.puts("  #{fail_indicator()} #{name} (#{duration}ms)")
    :ok
  end

  @doc """
  Print failure details.
  """
  @spec failure_detail(map()) :: :ok
  def failure_detail(%{scenario: name, result: {:failed, reason}}) do
    IO.puts("")
    IO.puts("  FAILURE: #{name}")
    IO.puts("  ---------")
    print_failure_reason(reason)
    IO.puts("")
    :ok
  end

  def failure_detail(_), do: :ok

  @doc """
  Print the test run summary.
  """
  @spec summary(map()) :: :ok
  def summary(summary) do
    IO.puts("")
    IO.puts(String.duplicate("=", 60))
    IO.puts("  SUMMARY")
    IO.puts(String.duplicate("-", 60))
    IO.puts("  Total:     #{summary.total}")
    IO.puts("  Passed:    #{summary.passed} (#{summary.pass_rate}%)")
    IO.puts("  Failed:    #{summary.failed}")
    IO.puts("  Duration:  #{format_duration(summary.duration)}")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")
    :ok
  end

  @doc """
  Print the test run footer.
  """
  @spec end_run(map()) :: :ok
  def end_run(summary) do
    if summary.failed == 0 do
      IO.puts("  #{pass_indicator()} All tests passed!")
    else
      IO.puts("  #{fail_indicator()} #{summary.failed} test(s) failed")
    end

    IO.puts("")
    :ok
  end

  # Private functions

  defp pass_indicator, do: "PASSED"
  defp fail_indicator, do: "FAILED"

  defp print_failure_reason({:exception, exception, stacktrace}) do
    IO.puts("  Exception: #{Exception.message(exception)}")
    IO.puts("  Stacktrace:")

    stacktrace
    |> Exception.format_stacktrace()
    |> String.split("\n")
    |> Enum.take(5)
    |> Enum.each(&IO.puts("    #{&1}"))
  end

  defp print_failure_reason({:timeout, _}) do
    IO.puts("  Timed out waiting for operation to complete")
  end

  defp print_failure_reason(:timeout) do
    IO.puts("  Scenario timed out")
  end

  defp print_failure_reason(reason) do
    IO.puts("  Reason: #{inspect(reason)}")
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = Float.round(rem(ms, 60_000) / 1000, 1)
    "#{minutes}m #{seconds}s"
  end
end
