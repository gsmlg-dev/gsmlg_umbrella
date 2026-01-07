defmodule GSMLG.CommanderTest.Scenarios.Scenario do
  @moduledoc """
  Behaviour for E2E test scenarios.

  A scenario is a complete test case that:
  1. Sets up test conditions
  2. Executes test actions
  3. Verifies expected outcomes
  4. Cleans up resources

  ## Usage

      defmodule MyScenario do
        use GSMLG.CommanderTest.Scenarios.Scenario

        @impl true
        def name, do: "my_scenario"

        @impl true
        def description, do: "Tests that something works"

        @impl true
        def tags, do: [:connection, :core]

        @impl true
        def run(context) do
          # context contains:
          # - :server - server info
          # - :ws_url - WebSocket URL
          # - :test_token - authentication token
          # - :config - test configuration

          # Perform test actions...

          :ok  # or {:error, reason}
        end
      end

  ## Available Imports

  When using this behaviour, the following are automatically imported:
  - `GSMLG.CommanderTest.Helpers.Assertions` - Test assertions
  - `GSMLG.CommanderTest.Helpers.Wait` - Polling utilities
  - `GSMLG.CommanderTest.Runner.AgentManager` - Agent management
  - `GSMLG.CommanderTest.Runner.ServerManager` - Server management
  - `GSMLG.CommanderTest.Helpers.ServerAPI` - Server HTTP helpers

  """

  @doc "Unique name for the scenario"
  @callback name() :: String.t()

  @doc "Human-readable description of what the scenario tests"
  @callback description() :: String.t()

  @doc "Tags for filtering scenarios (e.g., [:connection, :core])"
  @callback tags() :: [atom()]

  @doc "Execute the scenario. Returns :ok on success or {:error, reason} on failure."
  @callback run(context :: map()) :: :ok | {:error, term()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour GSMLG.CommanderTest.Scenarios.Scenario

      import GSMLG.CommanderTest.Helpers.Assertions
      import GSMLG.CommanderTest.Helpers.Wait

      alias GSMLG.CommanderTest.Runner.{AgentManager, ServerManager}
      alias GSMLG.CommanderTest.Helpers.ServerAPI
      alias GSMLG.CommanderTest.Helpers.ConfigGenerator
    end
  end
end
