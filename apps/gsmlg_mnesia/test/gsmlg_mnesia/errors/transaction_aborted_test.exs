defmodule GSMLGMnesia.Tests.TransactionAborted do
  use GSMLGMnesia.Support.Case, async: true
  require GSMLGMnesia.TransactionAborted

  describe "#raise" do
    @reason :something_went_wrong
    test "raises error with the given reason" do
      expected_reason = ~r/transaction aborted .* #{inspect(@reason)}/i

      assert_raise(GSMLGMnesia.TransactionAborted, expected_reason, fn ->
        GSMLGMnesia.TransactionAborted.raise(@reason)
      end)
    end
  end
end
