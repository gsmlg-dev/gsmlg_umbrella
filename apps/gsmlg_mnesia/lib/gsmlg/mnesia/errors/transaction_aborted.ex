defmodule GSMLG.Mnesia.TransactionAborted do
  defexception [:message]

  @moduledoc false

  # Raise a GSMLG.Mnesia.TransactionAborted
  defmacro raise(reason) do
    quote(bind_quoted: [reason: reason]) do
      raise GSMLG.Mnesia.TransactionAborted,
        message: "Transaction aborted with: #{inspect(reason)}"
    end
  end
end
