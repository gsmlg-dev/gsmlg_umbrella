defmodule GSMLG.CommanderTest.Helpers.Wait do
  @moduledoc """
  Polling utilities for E2E tests.

  Provides functions to wait for conditions to be met,
  with configurable timeouts and polling intervals.

  """

  @default_timeout 5_000
  @default_interval 100

  @doc """
  Wait until a condition is true.

  ## Options

    * `:timeout` - Maximum wait time in milliseconds (default: 5000)
    * `:interval` - Polling interval in milliseconds (default: 100)

  ## Examples

      # Wait for connection
      wait_until(fn -> Agent.status(id) == :connected end)

      # Wait with custom timeout
      wait_until(fn -> something() end, timeout: 10_000)

  """
  @spec wait_until((() -> boolean()), keyword()) :: :ok | {:error, :timeout}
  def wait_until(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(condition_fn, deadline, interval)
  end

  defp do_wait_until(condition_fn, deadline, interval) do
    if condition_fn.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_wait_until(condition_fn, deadline, interval)
      else
        {:error, :timeout}
      end
    end
  end

  @doc """
  Wait until a condition is true, raising on timeout.

  Same as `wait_until/2` but raises an exception on timeout.

  """
  @spec wait_until!((() -> boolean()), keyword()) :: :ok
  def wait_until!(condition_fn, opts \\ []) do
    case wait_until(condition_fn, opts) do
      :ok -> :ok
      {:error, :timeout} -> raise "Timeout waiting for condition"
    end
  end

  @doc """
  Wait for an agent to reach a specific status.

  ## Examples

      wait_for_status(agent_id, :connected)
      wait_for_status(agent_id, :connected, timeout: 10_000)

  """
  @spec wait_for_status(String.t(), atom(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_status(agent_id, expected_status, opts \\ []) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    wait_until(
      fn ->
        case AgentManager.get_status(agent_id) do
          ^expected_status -> true
          _ -> false
        end
      end,
      opts
    )
  end

  @doc """
  Wait for PTY output containing a specific string.

  ## Options

    * `:containing` - String that must be present in output
    * `:timeout` - Maximum wait time (default: 5000)

  ## Examples

      output = wait_for_output(agent_id, pty_id, containing: "hello")

  """
  @spec wait_for_output(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :timeout}
  def wait_for_output(agent_id, pty_id, opts \\ []) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    expected = Keyword.get(opts, :containing)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_output(agent_id, pty_id, expected, deadline, interval, "")
  end

  defp do_wait_for_output(agent_id, pty_id, expected, deadline, interval, accumulated) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    case AgentManager.get_pty_output(agent_id, pty_id) do
      {:ok, new_output} ->
        output = accumulated <> new_output

        cond do
          is_nil(expected) and output != "" ->
            {:ok, output}

          is_binary(expected) and String.contains?(output, expected) ->
            {:ok, output}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timeout}

          true ->
            Process.sleep(interval)
            do_wait_for_output(agent_id, pty_id, expected, deadline, interval, output)
        end

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          do_wait_for_output(agent_id, pty_id, expected, deadline, interval, accumulated)
        end
    end
  end

  @doc """
  Wait for a PTY to be ready.

  ## Examples

      wait_for_pty_ready(agent_id, pty_id)

  """
  @spec wait_for_pty_ready(String.t(), String.t(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_pty_ready(agent_id, pty_id, opts \\ []) do
    alias GSMLG.CommanderTest.Helpers.ServerAPI

    wait_until(
      fn ->
        case ServerAPI.get_pty_status(agent_id, pty_id) do
          {:ok, status} when status in [:ready, :active] -> true
          _ -> false
        end
      end,
      opts
    )
  end

  @doc """
  Wait for all agents to be connected.

  ## Examples

      wait_all_connected([agent1, agent2, agent3], timeout: 10_000)

  """
  @spec wait_all_connected([String.t()], keyword()) :: :ok | {:error, :timeout}
  def wait_all_connected(agent_ids, opts \\ []) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    wait_until(
      fn ->
        Enum.all?(agent_ids, fn agent_id ->
          AgentManager.get_status(agent_id) == :connected
        end)
      end,
      opts
    )
  end

  @doc """
  Sleep for a specified duration.

  This is a simple wrapper around Process.sleep for clarity in test scenarios.

  ## Examples

      sleep(1000)  # Sleep for 1 second

  """
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(ms) do
    Process.sleep(ms)
    :ok
  end
end
