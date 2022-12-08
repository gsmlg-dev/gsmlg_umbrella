defmodule GSMLG.Mnesia.Tests.Error do
  use GSMLG.Mnesia.Support.Case, async: true
  require GSMLG.Mnesia.Error

  describe "#raise" do
    test "raises error with default message" do
      assert_raise(GSMLG.Mnesia.Error, "Operation Failed", fn ->
        GSMLG.Mnesia.Error.raise()
      end)
    end

    @message "Something Happened"
    test "raises error with given message" do
      assert_raise(GSMLG.Mnesia.Error, @message, fn ->
        GSMLG.Mnesia.Error.raise(@message)
      end)
    end
  end

  describe "#raise_from_code" do
    # Testing just one code here. The rest should also work if all the
    # test cases for #normalize pass, since all this does is raise the
    # error resolved by that
    @mnesia_code :no_transaction
    test "raises the correct gsmlg_mnesia error from mnesia code" do
      assert_raise(GSMLG.Mnesia.NoTransactionError, fn ->
        GSMLG.Mnesia.Error.raise_from_code(@mnesia_code)
      end)
    end
  end

  describe "#normalize" do
    test "resolves to AlreadyExistsError for :already_exists" do
      assert %GSMLG.Mnesia.AlreadyExistsError{} =
               GSMLG.Mnesia.Error.normalize({:already_exists, X})
    end

    test "resolves to DoesNotExistError for :no_exists" do
      assert %GSMLG.Mnesia.DoesNotExistError{} = GSMLG.Mnesia.Error.normalize({:no_exists, X})
    end

    test "resolves to NoTransactionError for :no_transaction" do
      assert %GSMLG.Mnesia.NoTransactionError{} = GSMLG.Mnesia.Error.normalize(:no_transaction)
    end

    test "resolves to InvalidOperationError for :autoincrement" do
      assert %GSMLG.Mnesia.InvalidOperationError{} =
               GSMLG.Mnesia.Error.normalize({:autoincrement, "blah blah"})
    end

    @rest_of_mnesia_errors ~w[
      nested_transaction bad_arg combine_error bad_index index_exists
      system_limit mnesia_down not_a_db_node bad_type node_not_running
      truncated_binary_file active illegal
    ]a
    test "falls back to MnesiaException for other errors" do
      Enum.each(@rest_of_mnesia_errors, fn error ->
        assert %GSMLG.Mnesia.MnesiaException{} = GSMLG.Mnesia.Error.normalize({error, X})
      end)
    end
  end
end
