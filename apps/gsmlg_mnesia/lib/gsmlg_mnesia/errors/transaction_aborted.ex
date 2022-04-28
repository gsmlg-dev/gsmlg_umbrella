defmodule GSMLGMnesia.TransactionAborted do
  defexception [:message]

  @moduledoc false

  # Raise a GSMLGMnesia.TransactionAborted
  defmacro raise(reason) do
    quote(bind_quoted: [reason: reason]) do
      raise GSMLGMnesia.TransactionAborted,
        message: "Transaction aborted with: #{inspect(reason)}"
    end
  end
end
