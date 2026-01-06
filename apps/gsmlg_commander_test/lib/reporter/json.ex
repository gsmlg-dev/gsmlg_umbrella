defmodule GSMLG.CommanderTest.Reporter.Json do
  @moduledoc """
  JSON reporter for E2E test results.

  Generates a JSON report file containing:
  - Test metadata (timestamps, configuration)
  - Individual scenario results
  - Summary statistics

  """

  @default_output_path "commander_e2e_report.json"

  @doc """
  Report test results to a JSON file.
  """
  @spec report([map()], map()) :: :ok
  def report(results, summary) do
    report = generate_report(results, summary)
    output_path = Application.get_env(:gsmlg_commander_test, :json_report_path, @default_output_path)

    case write_report(report, output_path) do
      :ok ->
        IO.puts("JSON report written to: #{output_path}")
        :ok

      {:error, reason} ->
        IO.puts("Failed to write JSON report: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Generate a report map from results and summary.
  """
  @spec generate_report([map()], map()) :: map()
  def generate_report(results, summary) do
    %{
      meta: %{
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        framework: "GSMLG.CommanderTest",
        version: "0.1.0"
      },
      summary: %{
        total: summary.total,
        passed: summary.passed,
        failed: summary.failed,
        pass_rate: summary.pass_rate,
        duration_ms: summary.duration
      },
      scenarios:
        Enum.map(results, fn result ->
          %{
            name: result.scenario,
            status: format_status(result.result),
            duration_ms: result.duration,
            tags: result.tags,
            error: format_error(result.result)
          }
        end)
    }
  end

  @doc """
  Write the report to a file.
  """
  @spec write_report(map(), String.t()) :: :ok | {:error, term()}
  def write_report(report, path) do
    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, {:encoding_failed, reason}}
    end
  end

  # Private functions

  defp format_status(:passed), do: "passed"
  defp format_status({:failed, _}), do: "failed"

  defp format_error(:passed), do: nil

  defp format_error({:failed, {:exception, exception, stacktrace}}) do
    %{
      type: "exception",
      message: Exception.message(exception),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.split("\n") |> Enum.take(10)
    }
  end

  defp format_error({:failed, :timeout}) do
    %{
      type: "timeout",
      message: "Scenario timed out"
    }
  end

  defp format_error({:failed, reason}) do
    %{
      type: "error",
      message: inspect(reason)
    }
  end
end
