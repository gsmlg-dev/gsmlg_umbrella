defmodule GSMLG.CommanderTest do
  @moduledoc """
  Commander E2E Testing Framework.

  This module provides a comprehensive end-to-end testing framework for the
  GSMLG Commander system. It allows testing the complete integrated system
  with real server, real agents, and real network communication.

  ## Overview

  The E2E testing system:
  1. Starts a real Commander server on a test port
  2. Starts real Commander agent clients
  3. Connects them over actual WebSocket connections
  4. Executes test scenarios across the full system
  5. Verifies behavior end-to-end

  ## Usage

      # Run all tests
      GSMLG.CommanderTest.run()

      # Run specific tags
      GSMLG.CommanderTest.run(tags: [:terminal])

      # Run with options
      GSMLG.CommanderTest.run(
        tags: [:core],
        parallel: false,
        timeout: 60_000
      )

      # List available scenarios
      GSMLG.CommanderTest.list_scenarios()

  ## CLI Usage

      # Run all E2E tests
      mix commander.e2e

      # Run with specific tags
      mix commander.e2e --tags terminal

      # List all scenarios
      mix commander.e2e --list

      # Run specific scenario
      mix commander.e2e --scenario connect_test

  """

  alias GSMLG.CommanderTest.Runner.TestRunner

  @doc """
  Run E2E tests.

  ## Options

    * `:tags` - Filter scenarios by tags (list of atoms)
    * `:scenario` - Run a specific scenario by name
    * `:parallel` - Run scenarios in parallel (default: false)
    * `:timeout` - Scenario timeout in milliseconds (default: 30_000)
    * `:port` - Server port (default: 14000)
    * `:reporters` - List of reporters (default: [:console])
    * `:verbose` - Enable verbose output (default: false)

  ## Returns

    * `{:ok, summary}` - Test run completed successfully
    * `{:error, reason}` - Test run failed

  ## Examples

      # Run all tests
      iex> GSMLG.CommanderTest.run()
      {:ok, %{total: 18, passed: 17, failed: 1}}

      # Run only terminal tests
      iex> GSMLG.CommanderTest.run(tags: [:terminal])
      {:ok, %{total: 6, passed: 6, failed: 0}}

  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    TestRunner.run(opts)
  end

  @doc """
  List all available test scenarios.

  ## Options

    * `:tags` - Filter by tags

  ## Returns

  List of scenario information maps.

  ## Examples

      iex> GSMLG.CommanderTest.list_scenarios()
      [
        %{name: "connect_test", tags: [:connection, :core], description: "..."},
        %{name: "auth_test", tags: [:connection, :auth], description: "..."}
      ]

  """
  @spec list_scenarios(keyword()) :: [map()]
  def list_scenarios(opts \\ []) do
    TestRunner.list_scenarios(opts)
  end

  @doc """
  Run a single scenario by name.

  ## Examples

      iex> GSMLG.CommanderTest.run_scenario("connect_test")
      {:ok, %{name: "connect_test", result: :passed, duration: 1234}}

  """
  @spec run_scenario(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_scenario(scenario_name, opts \\ []) do
    TestRunner.run_single(scenario_name, opts)
  end

  @doc """
  Get the default configuration for E2E tests.
  """
  @spec default_config() :: map()
  def default_config do
    %{
      server_port: Application.get_env(:gsmlg_commander_test, :server_port, 14000),
      connect_timeout: Application.get_env(:gsmlg_commander_test, :connect_timeout, 5_000),
      scenario_timeout: Application.get_env(:gsmlg_commander_test, :scenario_timeout, 30_000),
      reporters: Application.get_env(:gsmlg_commander_test, :reporters, [:console])
    }
  end
end
