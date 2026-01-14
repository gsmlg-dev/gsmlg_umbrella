defmodule GSMLG.Mnesia.Tests.Table.Definition do
  use GSMLG.Mnesia.Support.Case
  @moduletag :mnesia
  alias GSMLG.Mnesia.Table.Definition

  # NOTE:
  # Put tests for `Definition.validate_options!` directly in
  # the test suite for `GSMLG.Mnesia.Table`, not here.

  @table Meta.User
  @attrs [:id, :name, :email]

  describe "#build_base" do
    @expected {@table, :"$1", :"$2", :"$3"}
    test "returns a tuple of match spec variables against a list of attrs" do
      assert @expected == Definition.build_base(@table, @attrs)
    end
  end

  describe "#build_map" do
    @expected %{id: :"$1", name: :"$2", email: :"$3"}
    test "returns a map with attributes as keys and match spec variables as values" do
      assert @expected == Definition.build_map(@attrs)
    end
  end

  describe "#struct_fields" do
    @expected [{:__meta__, GSMLG.Mnesia.Table} | @attrs]
    test "prepends attribute list with :__meta__ field" do
      assert @expected == Definition.struct_fields(@attrs)
    end
  end

  describe "#build_options" do
    @opts [attributes: @attrs, type: :ordered_set, autoincrement: true]
    test "separates gsmlg_mnesia and mnesia options" do
      %{gsmlg_mnesia: gsmlg_mnesia, mnesia: mnesia} = Definition.build_options(@opts)

      assert mnesia[:type] == :ordered_set
      assert gsmlg_mnesia[:autoincrement] == true
    end

    @opts [attributes: @attrs, index: [:id], type: :bag]
    test "removes attributes key" do
      %{mnesia: opts} = Definition.build_options(@opts)

      assert opts[:type] == :bag
      assert opts[:index] == [:id]
      refute opts[:attributes]
    end
  end

  describe "#merge_options" do
    @existing %{
      mnesia: [type: :ordered_set, index: [:id]],
      gsmlg_mnesia: [autoincrement: true]
    }
    @new [type: :set, autoincrement: false]

    test "does nothing for empty options" do
      assert @existing == Definition.merge_options(@existing, [])
    end

    test "overrides old options when specified" do
      assert %{gsmlg_mnesia: gsmlg_mnesia, mnesia: mnesia} =
               Definition.merge_options(@existing, @new)

      assert Keyword.get(gsmlg_mnesia, :autoincrement) == false
      assert Keyword.get(mnesia, :type) == :set
      assert Keyword.get(mnesia, :index) == [:id]
    end
  end

  describe "#validate_table!" do
    test "raises error for non gsmlg_mnesia table modules/terms" do
      assert_raise(GSMLG.Mnesia.Error, ~r/is not a GSMLG.Mnesia Table/i, fn ->
        Definition.validate_table!(SomeRandomModule)
      end)

      assert_raise(GSMLG.Mnesia.Error, ~r/is not a GSMLG.Mnesia Table/i, fn ->
        Definition.validate_table!(1234)
      end)
    end

    test "returns :ok for valid gsmlg_mnesia tables" do
      defmodule Meta.Simple do
        use GSMLG.Mnesia.Table, attributes: [:id, :username]
      end

      assert :ok = Definition.validate_table!(Meta.Simple)
    end
  end

  describe "#has_autoincrement?" do
    test "returns true for GSMLG.Mnesia Tables that have autoincrement" do
      defmodule Meta.AutoIncrementUser do
        use GSMLG.Mnesia.Table,
          attributes: [:id, :full_name],
          type: :ordered_set,
          autoincrement: true
      end

      assert Definition.has_autoincrement?(Meta.AutoIncrementUser)
    end

    test "returns false for GSMLG.Mnesia Tables that don't have autoincrement" do
      defmodule Meta.NoAutoIncrementUser do
        use GSMLG.Mnesia.Table, attributes: [:id, :full_name]
      end

      refute Definition.has_autoincrement?(Meta.NoAutoIncrementUser)
    end
  end
end
