defmodule GSMLG.Mnesia do
  require GSMLG.Mnesia.Mnesia
  require GSMLG.Mnesia.Error

  @moduledoc """
  Simple + Powerful interface to the Erlang Mnesia Database.


  See the [README](https://github.com/gsmlg-dev/gsmlg_umbrella) to get
  started.
  """

  # Public API
  # ----------

  @doc """
  Start the GSMLG.Mnesia Application.

  This starts GSMLG.Mnesia and `:mnesia` along with some sane application
  defaults. See `:mnesia.start/0` for more details.
  """
  @spec start() :: :ok | {:error, any}
  def start do
    Application.start(:mnesia)
  end

  @doc """
  Stop the GSMLG.Mnesia Application.
  """
  @spec stop() :: :ok | {:error, any}
  def stop do
    Application.stop(:mnesia)
  end

  @doc """
  Tells GSMLG.Mnesia about other nodes running GSMLG.Mnesia/Mnesia.

  You can use this to connect to and synchronize with other
  nodes at runtime and/or on discovery, to take full advantage
  of the distribution mode of GSMLG.Mnesia and Mnesia.

  This is a wrapper method around `:mnesia.change_config/2`.


  ## Example

  ```
  # Connect to GSMLG.Mnesia running on a specific node
  GSMLG.Mnesia.add_nodes(:node_xyz@some_host)

  # Add all connected nodes to GSMLG.Mnesia distributed database
  GSMLG.Mnesia.add_nodes(Node.list())
  ```
  """
  @spec add_nodes(node | list(node)) :: {:ok, list(node)} | {:error, any}
  def add_nodes(nodes) do
    nodes = List.wrap(nodes)

    if Enum.any?(nodes, &(!is_atom(&1))) do
      GSMLG.Mnesia.Error.raise("Invalid Node list passed")
    end

    GSMLG.Mnesia.Mnesia.call(:change_config, [:extra_db_nodes, nodes])
  end

  @doc """
  Prints `:mnesia` information to console.
  """
  @spec info() :: :ok
  def info do
    GSMLG.Mnesia.Mnesia.call(:info, [])
  end

  @doc """
  Returns all information about the Mnesia system.

  Optionally accepts a `key` atom argument which returns result for
  only that key. Will throw an exception if that key is invalid. See
  `:mnesia.system_info/0` for more information and a full list of
  allowed keys.
  """
  @spec system(atom) :: any
  def system(key \\ :all) do
    GSMLG.Mnesia.Mnesia.call(:system_info, [key])
  end

  # Delegates

  defdelegate wait(tables), to: GSMLG.Mnesia.Table
  defdelegate wait(tables, timeout), to: GSMLG.Mnesia.Table

  defdelegate transaction(fun), to: GSMLG.Mnesia.Transaction, as: :execute
  defdelegate transaction!(fun), to: GSMLG.Mnesia.Transaction, as: :execute!
end
