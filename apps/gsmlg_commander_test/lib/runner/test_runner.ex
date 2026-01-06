defmodule GSMLG.CommanderTest.Runner.TestRunner do
  @moduledoc """
  Main E2E test orchestrator.

  This module coordinates the entire E2E test execution:
  1. Starts the Commander server
  2. Creates test tokens
  3. Discovers and executes scenarios
  4. Collects results and generates reports

  ## Usage

      # Run all tests
      TestRunner.run()

      # Run specific tags
      TestRunner.run(tags: [:terminal])

      # Run with options
      TestRunner.run(
        tags: [:core],
        parallel: false,
        timeout: 60_000
      )

  """

  alias GSMLG.CommanderTest.Runner.{ServerManager, ScenarioExecutor}
  alias GSMLG.CommanderTest.Reporter

  require Logger

  @default_port 14000
  @default_timeout 30_000

  @doc """
  Run E2E tests with the given options.

  ## Options

    * `:tags` - Filter scenarios by tags
    * `:timeout` - Scenario timeout in milliseconds
    * `:port` - Server port
    * `:verbose` - Enable verbose output
    * `:reporters` - List of reporters to use

  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    config = build_config(opts)

    IO.puts("\nStarting Commander E2E Tests\n")

    with {:ok, server} <- start_server(config),
         context <- build_context(server, config),
         scenarios <- discover_scenarios(opts[:tags]),
         results <- execute_scenarios(scenarios, context, config),
         :ok <- stop_server() do
      summary = summarize(results)
      report_results(results, summary, config)
      {:ok, summary}
    else
      {:error, reason} = error ->
        IO.puts("\nError during test execution: #{inspect(reason)}")
        # Ensure cleanup
        stop_server()
        error
    end
  end

  @doc """
  Run a single scenario by name.
  """
  @spec run_single(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_single(scenario_name, opts \\ []) do
    config = build_config(opts)

    case find_scenario_by_name(scenario_name) do
      nil ->
        {:error, :not_found}

      scenario_module ->
        with {:ok, server} <- start_server(config),
             context <- build_context(server, config) do
          result = ScenarioExecutor.execute(scenario_module, context, config)
          stop_server()
          {:ok, result}
        end
    end
  end

  @doc """
  List all available scenarios.
  """
  @spec list_scenarios(keyword()) :: [map()]
  def list_scenarios(opts \\ []) do
    tags = opts[:tags]

    discover_scenario_modules()
    |> Enum.map(&scenario_info/1)
    |> filter_by_tags(tags)
  end

  # Private functions

  defp build_config(opts) do
    %{
      port: Keyword.get(opts, :port, config_value(:server_port, @default_port)),
      timeout: Keyword.get(opts, :timeout, config_value(:scenario_timeout, @default_timeout)),
      verbose: Keyword.get(opts, :verbose, false),
      reporters: Keyword.get(opts, :reporters, config_value(:reporters, [:console])),
      connect_timeout: config_value(:connect_timeout, 5_000),
      server_config: config_value(:server_config, [])
    }
  end

  defp config_value(key, default) do
    Application.get_env(:gsmlg_commander_test, key, default)
  end

  defp start_server(config) do
    IO.puts("Starting Commander server on port #{config.port}...")

    case ServerManager.start_server(port: config.port, config: config.server_config) do
      {:ok, server} ->
        IO.puts("Server started successfully\n")
        {:ok, server}

      {:error, reason} ->
        IO.puts("Failed to start server: #{inspect(reason)}")
        {:error, {:server_start_failed, reason}}
    end
  end

  defp stop_server do
    IO.puts("\nStopping server...")
    ServerManager.stop_server()
  end

  defp build_context(server, config) do
    %{
      server: server,
      ws_url: server.ws_url,
      port: config.port,
      test_token: nil,
      config: config
    }
  end

  defp discover_scenarios(tags) do
    discover_scenario_modules()
    |> filter_modules_by_tags(tags)
  end

  defp discover_scenario_modules do
    # Discover all modules that implement the Scenario behaviour
    # In a real implementation, this would scan the scenarios directory
    # For now, return an empty list until scenarios are implemented
    []
  end

  defp filter_modules_by_tags(modules, nil), do: modules

  defp filter_modules_by_tags(modules, tags) do
    Enum.filter(modules, fn module ->
      scenario_tags = module.tags()
      Enum.any?(tags, &(&1 in scenario_tags))
    end)
  end

  defp filter_by_tags(scenarios, nil), do: scenarios

  defp filter_by_tags(scenarios, tags) do
    Enum.filter(scenarios, fn scenario ->
      Enum.any?(tags, &(&1 in scenario[:tags]))
    end)
  end

  defp scenario_info(module) do
    %{
      module: module,
      name: module.name(),
      description: module.description(),
      tags: module.tags(),
      category: get_category(module)
    }
  end

  defp get_category(module) do
    module
    |> Module.split()
    |> Enum.at(-2, "general")
    |> String.downcase()
    |> String.to_atom()
  end

  defp find_scenario_by_name(name) do
    discover_scenario_modules()
    |> Enum.find(fn module -> module.name() == name end)
  end

  defp execute_scenarios(scenarios, context, config) do
    total = length(scenarios)
    IO.puts("Found #{total} scenarios to run\n")

    scenarios
    |> Enum.with_index(1)
    |> Enum.map(fn {scenario_module, index} ->
      IO.write("  [#{index}/#{total}] #{scenario_module.name()}... ")
      result = ScenarioExecutor.execute(scenario_module, context, config)
      print_result(result)
      result
    end)
  end

  defp print_result(%{result: :passed, duration: duration}) do
    IO.puts("PASSED (#{duration}ms)")
  end

  defp print_result(%{result: {:failed, reason}, duration: duration}) do
    IO.puts("FAILED (#{duration}ms)")
    IO.puts("    Error: #{inspect(reason)}")
  end

  defp summarize(results) do
    total = length(results)
    passed = Enum.count(results, &(&1.result == :passed))
    failed = total - passed
    duration = Enum.sum(Enum.map(results, & &1.duration))

    %{
      total: total,
      passed: passed,
      failed: failed,
      duration: duration,
      pass_rate: if(total > 0, do: Float.round(passed / total * 100, 1), else: 0.0)
    }
  end

  defp report_results(results, summary, config) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("\nSUMMARY")
    IO.puts("--------")
    IO.puts("Total:    #{summary.total}")
    IO.puts("Passed:   #{summary.passed} (#{summary.pass_rate}%)")
    IO.puts("Failed:   #{summary.failed}")
    IO.puts("Duration: #{format_duration(summary.duration)}")

    if summary.failed > 0 do
      IO.puts("\nFailed scenarios:")

      results
      |> Enum.filter(&(&1.result != :passed))
      |> Enum.each(fn result ->
        IO.puts("  - #{result.scenario}")
      end)
    end

    IO.puts("")

    # Call configured reporters
    Enum.each(config.reporters, fn reporter ->
      Reporter.report(reporter, results, summary)
    end)
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
