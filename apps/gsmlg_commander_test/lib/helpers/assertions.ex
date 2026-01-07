defmodule GSMLG.CommanderTest.Helpers.Assertions do
  @moduledoc """
  Test assertions for E2E scenarios.

  Provides assertion functions that raise on failure,
  with clear error messages for debugging.

  """

  @doc """
  Assert that a condition is true.

  ## Examples

      assert true
      assert 1 + 1 == 2

  """
  defmacro assert(condition) do
    quote do
      unless unquote(condition) do
        raise GSMLG.CommanderTest.AssertionError,
          message: "Assertion failed: #{unquote(Macro.to_string(condition))}"
      end

      :ok
    end
  end

  @doc """
  Assert that two values are equal.

  ## Examples

      assert_equal 1, 1
      assert_equal "hello", String.downcase("HELLO")

  """
  def assert_equal(expected, actual) do
    if expected == actual do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  @doc """
  Assert that a value matches a pattern.
  """
  defmacro assert_match(pattern, value) do
    quote do
      case unquote(value) do
        unquote(pattern) ->
          :ok

        other ->
          raise GSMLG.CommanderTest.AssertionError,
            message:
              "Pattern match failed. Expected #{unquote(Macro.to_string(pattern))}, got #{inspect(other)}"
      end
    end
  end

  @doc """
  Assert that a string contains a substring or list contains an element.

  ## Examples

      assert_contains "hello world", "world"
      assert_contains [1, 2, 3], 2

  """
  def assert_contains(string, substring)

  def assert_contains(string, substring) when is_binary(string) and is_binary(substring) do
    if String.contains?(string, substring) do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected string to contain #{inspect(substring)}, got: #{inspect(string)}"
    end
  end

  def assert_contains(list, element) when is_list(list) do
    if element in list do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected list to contain #{inspect(element)}, list: #{inspect(list)}"
    end
  end

  @doc """
  Assert that an agent is connected.
  """
  def assert_connected(agent_id) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    case AgentManager.get_status(agent_id) do
      :connected ->
        :ok

      status ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "Expected agent #{agent_id} to be connected, got: #{inspect(status)}"
    end
  end

  @doc """
  Assert that an agent is disconnected.
  """
  def assert_disconnected(agent_id) do
    alias GSMLG.CommanderTest.Runner.AgentManager

    case AgentManager.get_status(agent_id) do
      :disconnected ->
        :ok

      status ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "Expected agent #{agent_id} to be disconnected, got: #{inspect(status)}"
    end
  end

  @doc """
  Assert that a PTY session exists.
  """
  def assert_pty_exists(agent_id, pty_id) do
    alias GSMLG.CommanderTest.Helpers.ServerAPI

    case ServerAPI.get_pty_status(agent_id, pty_id) do
      {:ok, status} when status in [:ready, :active] ->
        :ok

      {:ok, status} ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "Expected PTY #{pty_id} to exist, got status: #{inspect(status)}"

      {:error, :not_found} ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "PTY #{pty_id} does not exist for agent #{agent_id}"

      {:error, reason} ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "Failed to check PTY status: #{inspect(reason)}"
    end
  end

  @doc """
  Assert that a result is an error of a specific type.

  ## Examples

      assert_error {:error, :invalid_token}, :invalid_token

  """
  def assert_error({:error, reason}, expected_type) when is_atom(expected_type) do
    actual_type =
      case reason do
        {type, _} when is_atom(type) -> type
        type when is_atom(type) -> type
        _ -> reason
      end

    if actual_type == expected_type do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected error type #{inspect(expected_type)}, got: #{inspect(reason)}"
    end
  end

  def assert_error(result, expected_type) do
    raise GSMLG.CommanderTest.AssertionError,
      message: "Expected {:error, #{inspect(expected_type)}}, got: #{inspect(result)}"
  end

  @doc """
  Assert that a function raises an exception.
  """
  defmacro assert_raise(exception_type, fun) do
    quote do
      try do
        unquote(fun).()

        raise GSMLG.CommanderTest.AssertionError,
          message: "Expected #{inspect(unquote(exception_type))} to be raised, but nothing was raised"
      rescue
        e in unquote(exception_type) ->
          :ok

        other ->
          raise GSMLG.CommanderTest.AssertionError,
            message:
              "Expected #{inspect(unquote(exception_type))}, got #{inspect(other.__struct__)}"
      end
    end
  end

  @doc """
  Assert that a value is not nil.
  """
  def assert_not_nil(value) do
    if is_nil(value) do
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected value to not be nil"
    else
      :ok
    end
  end

  @doc """
  Assert that a value is nil.
  """
  def assert_nil(value) do
    if is_nil(value) do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected nil, got: #{inspect(value)}"
    end
  end

  @doc """
  Assert that a map has a key.
  """
  def assert_has_key(map, key) when is_map(map) do
    if Map.has_key?(map, key) do
      :ok
    else
      raise GSMLG.CommanderTest.AssertionError,
        message: "Expected map to have key #{inspect(key)}, keys: #{inspect(Map.keys(map))}"
    end
  end

  @doc """
  Assert that a map has a key with a specific value.
  """
  def assert_has_key(map, key, expected_value) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, ^expected_value} ->
        :ok

      {:ok, actual_value} ->
        raise GSMLG.CommanderTest.AssertionError,
          message:
            "Expected map[#{inspect(key)}] to be #{inspect(expected_value)}, got: #{inspect(actual_value)}"

      :error ->
        raise GSMLG.CommanderTest.AssertionError,
          message: "Expected map to have key #{inspect(key)}, keys: #{inspect(Map.keys(map))}"
    end
  end
end

defmodule GSMLG.CommanderTest.AssertionError do
  @moduledoc """
  Exception raised when an assertion fails.
  """
  defexception [:message]
end
