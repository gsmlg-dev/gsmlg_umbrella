defmodule GSMLG.CommanderTest.Runner.ScenarioExecutor do
  @moduledoc """
  Executes individual test scenarios.

  Handles scenario lifecycle:
  1. Setup scenario context
  2. Execute scenario steps
  3. Capture errors and timeouts
  4. Return structured results

  """

  require Logger

  @default_timeout 30_000

  @doc """
  Execute a scenario module.

  ## Parameters

    * `scenario_module` - The scenario module to execute
    * `context` - Test context with server info and tokens
    * `config` - Test configuration

  ## Returns

  A map with:
    * `:scenario` - Scenario name
    * `:result` - `:passed` or `{:failed, reason}`
    * `:duration` - Execution time in milliseconds

  """
  @spec execute(module(), map(), map()) :: map()
  def execute(scenario_module, context, config) do
    timeout = Map.get(config, :timeout, @default_timeout)
    scenario_name = scenario_module.name()

    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        task =
          Task.async(fn ->
            scenario_module.run(context)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, :ok} ->
            :passed

          {:ok, {:error, reason}} ->
            {:failed, reason}

          nil ->
            {:failed, :timeout}
        end
      rescue
        exception ->
          {:failed, {:exception, exception, __STACKTRACE__}}
      catch
        kind, reason ->
          {:failed, {kind, reason, __STACKTRACE__}}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    %{
      scenario: scenario_name,
      module: scenario_module,
      result: result,
      duration: duration,
      tags: scenario_module.tags()
    }
  end

  @doc """
  Execute multiple scenarios.

  ## Options

    * `:parallel` - Run scenarios in parallel (default: false)

  """
  @spec execute_all([module()], map(), map()) :: [map()]
  def execute_all(scenarios, context, config) do
    parallel = Map.get(config, :parallel, false)

    if parallel do
      execute_parallel(scenarios, context, config)
    else
      execute_sequential(scenarios, context, config)
    end
  end

  defp execute_sequential(scenarios, context, config) do
    Enum.map(scenarios, &execute(&1, context, config))
  end

  defp execute_parallel(scenarios, context, config) do
    scenarios
    |> Enum.map(fn scenario ->
      Task.async(fn -> execute(scenario, context, config) end)
    end)
    |> Enum.map(&Task.await(&1, :infinity))
  end
end
