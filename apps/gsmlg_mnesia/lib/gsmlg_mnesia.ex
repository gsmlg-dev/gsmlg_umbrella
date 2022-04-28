defmodule GSMLGMnesia do
  require GSMLGMnesia.Mnesia
  require GSMLGMnesia.Error

  @moduledoc """
  Simple + Powerful interface to the Erlang Mnesia Database.


  See the [README](https://github.com/gsmlg-dev/gsmlg_umbrella) to get
  started.
  """

  # Public API
  # ----------

  @doc """
  Start the GSMLGMnesia Application.

  This starts GSMLGMnesia and `:mnesia` along with some sane application
  defaults. See `:mnesia.start/0` for more details.
  """
  @spec start() :: :ok | {:error, any}
  def start do
    Application.start(:mnesia)
  end

  @doc """
  Stop the GSMLGMnesia Application.
  """
  @spec stop() :: :ok | {:error, any}
  def stop do
    Application.stop(:mnesia)
  end

  @doc """
  Tells GSMLGMnesia about other nodes running GSMLGMnesia/Mnesia.

  You can use this to connect to and synchronize with other
  nodes at runtime and/or on discovery, to take full advantage
  of the distribution mode of GSMLGMnesia and Mnesia.

  This is a wrapper method around `:mnesia.change_config/2`.


  ## Example

  ```
  # Connect to GSMLGMnesia running on a specific node
  GSMLGMnesia.add_nodes(:node_xyz@some_host)

  # Add all connected nodes to GSMLGMnesia distributed database
  GSMLGMnesia.add_nodes(Node.list())
  ```
  """
  @spec add_nodes(node | list(node)) :: {:ok, list(node)} | {:error, any}
  def add_nodes(nodes) do
    nodes = List.wrap(nodes)

    if Enum.any?(nodes, &(!is_atom(&1))) do
      GSMLGMnesia.Error.raise("Invalid Node list passed")
    end

    GSMLGMnesia.Mnesia.call(:change_config, [:extra_db_nodes, nodes])
  end

  @doc """
  Prints `:mnesia` information to console.
  """
  @spec info() :: :ok
  def info do
    GSMLGMnesia.Mnesia.call(:info, [])
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
    GSMLGMnesia.Mnesia.call(:system_info, [key])
  end

  # Delegates

  defdelegate wait(tables), to: GSMLGMnesia.Table
  defdelegate wait(tables, timeout), to: GSMLGMnesia.Table

  defdelegate transaction(fun), to: GSMLGMnesia.Transaction, as: :execute
  defdelegate transaction!(fun), to: GSMLGMnesia.Transaction, as: :execute!
end
