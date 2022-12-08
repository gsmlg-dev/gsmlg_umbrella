defmodule GSMLG.Mnesia.Table.Definition do
  require GSMLG.Mnesia.Error

  @moduledoc false

  # Helper module to build GSMLG.Mnesia Tables with the `use` macro.
  # This module is used to define GSMLG.Mnesia Tables at compile
  # time, so this not be used directly (unless you absolutely
  # know what you're doing).

  # Type Definitions
  # ----------------

  @typedoc "Normalized options of a Table"
  @type options :: %{gsmlg_mnesia: Keyword.t(), mnesia: Keyword.t()}

  # Helper API
  # ----------

  @doc """
  Builds the base of the `match_spec`, to be later used
  in `select` calls. Should ideally be called once
  during compile-time.

  Takes attribute keywords or list `[:a, :b, :c, ...]`
  and converts them into `{module, :$1, :$2, ...}`
  """
  @spec build_base(GSMLG.Mnesia.Table.name(), list) :: tuple
  def build_base(module, attributes) do
    attributes =
      attributes
      |> Enum.count()
      |> Range.new(1)
      |> Enum.reverse()
      |> Enum.map(&:"$#{&1}")

    List.to_tuple([module | attributes])
  end

  @doc """
  Builds a map with attributes and their corresponding
  keys, to later help with quickly replacing attributes
  with their ids. Should ideally be called once during
  compile-time.

  Takes attribute keywords `[a: nil, b: nil, ...]` or
  list, and converts them into `%{a: :$1, b: :$2, ...}`
  """
  @spec build_map(list) :: map
  def build_map(attributes) do
    attributes
    |> Enum.reduce({%{}, 1}, &build_reducer/2)
    |> elem(0)
  end

  @doc """
  Builds the list of fields to be passed to `defstruct`
  in the Table definition at compile-time.

  Prepends an extra `:__meta__` field with the default
  value of `GSMLG.Mnesia.Table`.
  """
  @spec build_map(list) :: list
  def struct_fields(attributes) do
    [{:__meta__, GSMLG.Mnesia.Table} | attributes]
  end

  @doc """
  Builds the GSMLG.Mnesia and Mnesia options for generating
  a Table.
  """
  @gsmlg_mnesia_opts [:autoincrement]
  @spec build_options(Keyword.t()) :: options
  def build_options(opts) do
    mnesia_opts = Keyword.drop(opts, [:attributes | @gsmlg_mnesia_opts])
    gsmlg_mnesia_opts = Keyword.take(opts, @gsmlg_mnesia_opts)

    # Return consolidated
    %{
      mnesia: mnesia_opts,
      gsmlg_mnesia: gsmlg_mnesia_opts
    }
  end

  @doc "Merges new options in to existing option map"
  @spec merge_options(options, Keyword.t()) :: options
  def merge_options(table_opts, opts) do
    %{mnesia: old_mnesia, gsmlg_mnesia: old_gsmlg_mnesia} = table_opts
    %{mnesia: new_mnesia, gsmlg_mnesia: new_gsmlg_mnesia} = build_options(opts)

    # Consolidate and Return
    %{
      mnesia: Keyword.merge(old_mnesia, new_mnesia),
      gsmlg_mnesia: Keyword.merge(old_gsmlg_mnesia, new_gsmlg_mnesia)
    }
  end

  @doc "Validate Table options"
  @allowed_types [:set, :ordered_set, :bag]
  @spec validate_options!(Keyword.t()) :: :ok | no_return
  def validate_options!(opts) do
    error =
      cond do
        !Keyword.keyword?(opts) ->
          "Invalid options specified"

        true ->
          attrs = Keyword.get(opts, :attributes)
          type = Keyword.get(opts, :type, :set)
          index = Keyword.get(opts, :index, [])
          auto = Keyword.get(opts, :autoincrement, false)

          cond do
            # No Attributes Specified
            attrs == nil ->
              "Table attributes not specified"

            # Attributes isn't a list
            !is_list(attrs) ->
              "Invalid attributes specified"

            # Attributes aren't atoms
            !Enum.all?(attrs, &is_atom/1) ->
              "Invalid attributes specified"

            # Index isn't a list
            !is_list(index) ->
              "Invalid index list specified"

            # Indices aren't atoms
            !Enum.all?(index, &is_atom/1) ->
              "Invalid index list specified"

            # Autoincrement isn't a boolean
            !is_boolean(auto) ->
              "Invalid autoincrement parameter specified"

            # Table type is not one of allowed
            !Enum.member?(@allowed_types, type) ->
              "Invalid table type specified"

            true ->
              nil
          end
      end

    case error do
      nil -> :ok
      error -> GSMLG.Mnesia.Error.raise(error)
    end
  end

  @doc "Check if Table supports autoincrement"
  @spec has_autoincrement?(GSMLG.Mnesia.Table.name()) :: boolean
  def has_autoincrement?(table) do
    opts = table.__info__().options.gsmlg_mnesia
    Keyword.get(opts, :autoincrement, false)
  end

  @doc "Raise error if a given module is not a valid GSMLG.Mnesia Table"
  @spec validate_table!(module) :: :ok | no_return
  def validate_table!(module) do
    GSMLG.Mnesia.Table = module.__info__.meta
    :ok
  rescue
    _ ->
      GSMLG.Mnesia.Error.raise("#{inspect(module)} is not a GSMLG.Mnesia Table")
  end

  # Private Helpers
  # ---------------

  # Helper function for building translation map.
  # Used in the reduce call inside `build_map`
  defp build_reducer(attr, {map, position}) when is_atom(attr) do
    {
      Map.put(map, attr, :"$#{position}"),
      position + 1
    }
  end
end
