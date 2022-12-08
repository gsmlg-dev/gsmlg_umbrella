defmodule GSMLG.Mnesia.Tests.TransactionAborted do
  use GSMLG.Mnesia.Support.Case, async: true
  require GSMLG.Mnesia.TransactionAborted

  describe "#raise" do
    @reason :something_went_wrong
    test "raises error with the given reason" do
      expected_reason = ~r/transaction aborted .* #{inspect(@reason)}/i

      assert_raise(GSMLG.Mnesia.TransactionAborted, expected_reason, fn ->
        GSMLG.Mnesia.TransactionAborted.raise(@reason)
      end)
    end
  end
end
