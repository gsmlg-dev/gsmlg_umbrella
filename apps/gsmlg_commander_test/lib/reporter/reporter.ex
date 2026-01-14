defmodule GSMLG.CommanderTest.Reporter do
  @moduledoc """
  Reporter behaviour and dispatcher for test results.

  Reporters can output results in various formats:
  - Console (default)
  - JSON
  - HTML

  """

  @doc """
  Dispatch to the appropriate reporter.
  """
  @spec report(atom(), [map()], map()) :: :ok
  def report(:console, results, summary) do
    GSMLG.CommanderTest.Reporter.Console.report(results, summary)
  end

  def report(:json, results, summary) do
    GSMLG.CommanderTest.Reporter.Json.report(results, summary)
  end

  def report(reporter, results, summary) when is_atom(reporter) do
    # Try to call custom reporter module
    module = Module.concat([GSMLG.CommanderTest.Reporter, Macro.camelize(to_string(reporter))])

    if Code.ensure_loaded?(module) do
      module.report(results, summary)
    else
      :ok
    end
  end

  def report(_, _, _), do: :ok
end
