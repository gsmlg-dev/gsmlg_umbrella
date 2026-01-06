defmodule Mix.Tasks.Commander.E2e do
  @moduledoc """
  Run Commander E2E tests.

  This task starts the Commander E2E test framework, which:
  1. Starts a real Commander server on a test port
  2. Starts real Commander agent clients
  3. Executes test scenarios across the full system
  4. Reports results

  ## Usage

      # Run all tests
      mix commander.e2e

      # Run tests with specific tags
      mix commander.e2e --tags terminal

      # Run multiple tags (comma-separated)
      mix commander.e2e --tags terminal,connection

      # List all available scenarios
      mix commander.e2e --list

      # Run a specific scenario
      mix commander.e2e --scenario connect_test

      # Run with custom timeout (in seconds)
      mix commander.e2e --timeout 60

      # Run in verbose mode
      mix commander.e2e --verbose

      # Specify custom port
      mix commander.e2e --port 15000

  ## Options

      --tags       Filter scenarios by tags (comma-separated)
      --scenario   Run a specific scenario by name
      --list       List all available scenarios
      --timeout    Scenario timeout in seconds (default: 30)
      --port       Server port (default: 14000)
      --verbose    Enable verbose output
      --json       Output results in JSON format

  ## Exit Codes

      0 - All tests passed
      1 - One or more tests failed
      2 - Error during test execution

  """

  use Mix.Task

  @shortdoc "Run Commander E2E tests"

  @switches [
    tags: :string,
    scenario: :string,
    list: :boolean,
    timeout: :integer,
    port: :integer,
    verbose: :boolean,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    # Ensure applications are started
    {:ok, _} = Application.ensure_all_started(:gsmlg_commander_test)

    cond do
      opts[:list] ->
        list_scenarios(opts)

      opts[:scenario] ->
        run_single_scenario(opts[:scenario], opts)

      true ->
        run_all_scenarios(opts)
    end
  end

  defp list_scenarios(opts) do
    tags = parse_tags(opts[:tags])

    scenarios = GSMLG.CommanderTest.list_scenarios(tags: tags)

    IO.puts("\nAvailable Commander E2E Scenarios")
    IO.puts("=" |> String.duplicate(50))
    IO.puts("")

    if Enum.empty?(scenarios) do
      IO.puts("  No scenarios found.")
    else
      scenarios
      |> Enum.group_by(fn s -> s[:category] || :general end)
      |> Enum.each(fn {category, scenarios} ->
        IO.puts("  #{String.upcase(to_string(category))}")

        Enum.each(scenarios, fn scenario ->
          tags_str = scenario[:tags] |> Enum.map(&to_string/1) |> Enum.join(", ")
          IO.puts("    - #{scenario[:name]}")
          IO.puts("      Tags: #{tags_str}")

          if scenario[:description] do
            IO.puts("      #{scenario[:description]}")
          end

          IO.puts("")
        end)
      end)
    end

    IO.puts("")
  end

  defp run_single_scenario(scenario_name, opts) do
    IO.puts("\nRunning scenario: #{scenario_name}\n")

    run_opts = build_run_opts(opts)

    case GSMLG.CommanderTest.run_scenario(scenario_name, run_opts) do
      {:ok, result} ->
        print_result(result)
        exit_with_code(result)

      {:error, :not_found} ->
        IO.puts("Error: Scenario '#{scenario_name}' not found.")
        IO.puts("Use 'mix commander.e2e --list' to see available scenarios.")
        System.halt(2)

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp run_all_scenarios(opts) do
    run_opts = build_run_opts(opts)

    case GSMLG.CommanderTest.run(run_opts) do
      {:ok, summary} ->
        if opts[:json] do
          IO.puts(Jason.encode!(summary, pretty: true))
        end

        exit_with_summary(summary)

      {:error, reason} ->
        IO.puts("\nError running E2E tests: #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp build_run_opts(opts) do
    base_opts = []

    base_opts =
      if opts[:tags] do
        Keyword.put(base_opts, :tags, parse_tags(opts[:tags]))
      else
        base_opts
      end

    base_opts =
      if opts[:timeout] do
        Keyword.put(base_opts, :timeout, opts[:timeout] * 1000)
      else
        base_opts
      end

    base_opts =
      if opts[:port] do
        Keyword.put(base_opts, :port, opts[:port])
      else
        base_opts
      end

    base_opts =
      if opts[:verbose] do
        Keyword.put(base_opts, :verbose, true)
      else
        base_opts
      end

    base_opts
  end

  defp parse_tags(nil), do: nil

  defp parse_tags(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp print_result(%{result: :passed} = result) do
    IO.puts("PASSED (#{result[:duration]}ms)")
  end

  defp print_result(%{result: {:failed, reason}} = result) do
    IO.puts("FAILED (#{result[:duration]}ms)")
    IO.puts("  Error: #{inspect(reason)}")
  end

  defp exit_with_code(%{result: :passed}), do: :ok
  defp exit_with_code(%{result: {:failed, _}}), do: System.halt(1)

  defp exit_with_summary(%{failed: 0}), do: :ok
  defp exit_with_summary(%{failed: _}), do: System.halt(1)
end
