defmodule GSMLG.CouchDB.DB do
  @moduledoc """
  Database-level operations for Apache CouchDB.

  This module provides functions for managing CouchDB databases including
  creation, deletion, compaction, security settings, and administrative tasks.

  ## Common Operations

      alias GSMLG.CouchDB.DB

      # List all databases
      DB.all_dbs()
      #=> ["_replicator", "_users", "myapp"]

      # Create database
      DB.create_db("myapp")
      #=> %{ok: true}

      # Get database info
      DB.info_db("myapp")
      #=> %{db_name: "myapp", doc_count: 123, ...}

      # Delete database
      DB.drop_db("old_db")
      #=> %{ok: true}

  ## Database Naming Rules

  Database names must:
  - Start with a lowercase letter (a-z)
  - Contain only: lowercase letters, digits, and the characters `_$()+-/`
  - Not start with an underscore (reserved for system databases)

  Valid examples: `"mydb"`, `"app_production"`, `"project-2024"`

  Invalid examples: `"MyDB"` (uppercase), `"123db"` (starts with digit), `"my.db"` (contains period)

  ## Security

  CouchDB uses a security object to control database access:

      # Get current security
      DB.get_security("myapp")

      # Set security (admins and members)
      DB.put_security("myapp", %{
        admins: %{names: ["admin"], roles: []},
        members: %{names: [], roles: ["user"]}
      })

  ## Maintenance

      # Compact database (reclaim disk space)
      DB.compact("myapp")

      # Compact design document views
      DB.compact("myapp", "design_doc_id")

      # Clean up old view index files
      DB.view_cleanup("myapp")
  """

  alias GSMLG.CouchDB.Connection

  def all_dbs() do
    Connection.get!("/_all_dbs")
  end

  def info_db(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name)
  end

  def create_db(db_name) do
    check_name!(db_name)
    Connection.put!("/" <> db_name)
  end

  def drop_db(db_name) do
    check_name!(db_name)
    Connection.delete!("/" <> db_name)
  end

  def get_shards(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_shards")
  end

  # _shards/doc
  def get_shards(db_name, docid) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_shards/" <> docid)
  end

  def sync_shards(db_name) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_sync_shards")
  end

  def changes(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_changes")
  end

  def compact(db_name) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_compact")
  end

  def compact(db_name, docid) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_compact/" <> docid)
  end

  # _view_cleanup
  def view_cleanup(db_name) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_view_cleanup")
  end

  def get_security(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_security")
  end

  def put_security(db_name, data) do
    check_name!(db_name)
    Connection.put!("/" <> db_name <> "/_security", data)
  end

  def purge(db_name, params) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_purge", params)
  end

  def get_purged_infos_limit(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_purged_infos_limit")
  end

  def put_purged_infos_limit(db_name, limit) do
    check_name!(db_name)
    Connection.put!("/" <> db_name <> "/_purged_infos_limit", limit)
  end

  def get_missing_revs(db_name, params) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_missing_revs", params)
  end

  def get_revs_diff(db_name, params) do
    check_name!(db_name)
    Connection.post!("/" <> db_name <> "/_revs_diff", params)
  end

  def get_revs_limit(db_name) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/_revs_limit")
  end

  def put_revs_limit(db_name, limit) do
    check_name!(db_name)
    Connection.put!("/" <> db_name <> "/_revs_limit", limit)
  end

  defp check_name(db_name) do
    ~r/^[a-z][a-z0-9_\$\(\)\+\/\-]*$/ |> Regex.match?(db_name)
  end

  defp check_name!(db_name) do
    if check_name(db_name) do
      :ok
    else
      raise "db name invalid"
    end
  end
end
