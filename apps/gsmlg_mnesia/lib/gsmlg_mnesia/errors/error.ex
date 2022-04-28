defmodule GSMLGMnesia.Error do
  alias GSMLGMnesia.InvalidOperationError
  alias GSMLGMnesia.NoTransactionError
  alias GSMLGMnesia.AlreadyExistsError
  alias GSMLGMnesia.DoesNotExistError
  alias GSMLGMnesia.MnesiaException

  defexception [:message]

  @moduledoc false
  @default_message "Operation Failed"

  # Macros to Raise Errors
  # ----------------------

  # Raise a GSMLGMnesia.Error
  defmacro raise(message \\ @default_message) do
    quote do
      raise GSMLGMnesia.Error, message: unquote(message)
    end
  end

  # Finds the appropriate GSMLGMnesia error from an Mnesia exit
  # Falls back to a default 'MnesiaException'
  defmacro raise_from_code(data) do
    quote(bind_quoted: [data: data]) do
      raise GSMLGMnesia.Error.normalize(data)
    end
  end

  # Error Builders
  # --------------

  # Helper Method to Build GSMLGMnesia Exceptions
  def normalize({:error, reason}), do: do_normalize(reason)
  def normalize({:aborted, reason}), do: do_normalize(reason)
  def normalize(reason), do: do_normalize(reason)

  defp do_normalize(reason) do
    case reason do
      # Mnesia Error Codes
      :no_transaction ->
        %NoTransactionError{message: "Not inside a GSMLGMnesia Transaction"}

      {:no_exists, resource} ->
        %DoesNotExistError{message: "#{inspect(resource)} does not exist or is not alive"}

      {:already_exists, resource} ->
        %AlreadyExistsError{message: "#{inspect(resource)} already exists"}

      # Custom Error Code - Not Part of Mnesia
      {:autoincrement, message} ->
        %InvalidOperationError{message: "Autoincrement #{message}"}

      # Don't need custom errors for the rest, fallback to MnesiaException
      # and raise with Mnesia's description of the error
      error ->
        MnesiaException.build(error)
    end
  end
end
