defmodule GSMLG.CommandPlatform.Commander do
  require Logger
  alias GSMLG.CommandPlatform
  alias GSMLG.CommandPlatform.Commander

  use GSMLG.Mnesia.Table,
    attributes: [
      :id,
      :name,
      :is_working,
      :jobs,
      :os,
      :arch,
      :cpu,
      :memory,
      :disk,
      :is_connected,
      :last_connected_time
    ]

  def ensure_table() do
    create_table_if_not_exists()
    migrate_table_schema()
    persist_data_to_disc()
  end

  def create_table_if_not_exists do
    case GSMLG.Mnesia.Table.create(CommandPlatform.Commander) do
      {{:atomic, :ok}, _metadata} ->
        :ok

      {{:error, {:already_exists, CommandPlatform.Commander}}, _metadata} ->
        :ok
    end
  end

  def migrate_table_schema() do
    case GSMLG.Mnesia.Table.info(CommandPlatform.Commander, :attributes) do
      [:id, :name, :jobs] ->
        GSMLG.Mnesia.Table.wait([CommandPlatform.Commander], 5000)

        GSMLG.Mnesia.Table.transform(
          CommandPlatform.Commander,
          fn {CommandPlatform.Commander, id, name, job} ->
            {CommandPlatform.Commander, id, name, job, 21}
          end,
          [:id, :name, :jobs, :age]
        )

        :ok

      attrs ->
        Logger.debug("Table attrs: #{inspect(attrs)}")
        :ok
    end
  end

  def persist_data_to_disc() do
    case GSMLG.Mnesia.Table.set_storage_type(CommandPlatform.Commander, node(), :disc_copies) do
      :ok -> :ok
      {:error, {:already_started, _, _, _}} -> :ok
      {:error, _} = error -> error
    end
  end

  def info(key \\ :all) do
    GSMLG.Mnesia.Table.info(__MODULE__, key)
  end

  def read(id, opts \\ []) do
    GSMLG.Mnesia.Transaction.execute_sync(fn ->
      GSMLG.Mnesia.Query.read(Commander, id, opts)
    end)
  end

  def write(attrs, opts \\ []) do
    GSMLG.Mnesia.Transaction.execute_sync(fn ->
      GSMLG.Mnesia.Query.write(Map.merge(%Commander{}, attrs), opts)
    end)
  end

  def delete(id, opts \\ []) do
    GSMLG.Mnesia.Transaction.execute_sync(fn ->
      GSMLG.Mnesia.Query.delete(Commander, id, opts)
    end)
  end

  def all(opts \\ []) do
    GSMLG.Mnesia.Transaction.execute_sync(fn ->
      GSMLG.Mnesia.Query.all(Commander, opts)
    end)
  end
end
