# GSMLG.Mnesia

A powerful and user-friendly Elixir wrapper for Erlang's Mnesia distributed database system. GSMLG.Mnesia provides an idiomatic Elixir API with struct-based records, simplified queries, and built-in telemetry support.

## Features

- **Idiomatic Elixir API**: Work with structs instead of raw Erlang tuples
- **Simple Table Definitions**: Define tables using simple module attributes
- **Powerful Query Interface**: Three query methods from simple to complex
- **Transaction Support**: Safe, automatic transaction retry logic
- **Distributed by Design**: Built-in support for multi-node replication
- **Autoincrement Keys**: Optional auto-incrementing primary keys for ordered sets
- **Type Safety**: Comprehensive typespecs throughout
- **Production Ready**: 109 tests, all passing

## Installation

Add `gsmlg_mnesia` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_mnesia, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Define Your Tables

```elixir
defmodule Blog.Post do
  use GSMLG.Mnesia.Table,
    attributes: [:id, :title, :content, :author_id, :published_at],
    index: [:author_id],
    type: :ordered_set,
    autoincrement: true

  # You can add helper functions here
  def published(post), do: !is_nil(post.published_at)
end

defmodule Blog.Author do
  use GSMLG.Mnesia.Table,
    attributes: [:id, :name, :email],
    type: :set
end
```

### 2. Create the Schema and Tables

```elixir
# Start Mnesia
GSMLG.Mnesia.start()

# Create database schema on disk (optional, for persistence)
GSMLG.Mnesia.Schema.create([node()])

# Create the tables
GSMLG.Mnesia.Table.create!(Blog.Post, disc_copies: [node()])
GSMLG.Mnesia.Table.create!(Blog.Author, disc_copies: [node()])

# Wait for tables to be ready
GSMLG.Mnesia.wait([Blog.Post, Blog.Author])
```

### 3. Perform CRUD Operations

```elixir
# Create records
GSMLG.Mnesia.transaction! fn ->
  # Autoincrement will assign ID automatically
  post = GSMLG.Mnesia.Query.write(%Blog.Post{
    title: "Getting Started with Mnesia",
    content: "Mnesia is a distributed database...",
    author_id: 1,
    published_at: DateTime.utc_now()
  })

  author = GSMLG.Mnesia.Query.write(%Blog.Author{
    id: 1,
    name: "John Doe",
    email: "john@example.com"
  })

  {post, author}
end

# Read records
GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.read(Blog.Post, 1)
end
# => %Blog.Post{id: 1, title: "Getting Started with Mnesia", ...}

# Get all records
GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.all(Blog.Post)
end

# Update records (just write with the same primary key)
GSMLG.Mnesia.transaction! fn ->
  post = GSMLG.Mnesia.Query.read(Blog.Post, 1)
  updated_post = %{post | title: "Updated Title"}
  GSMLG.Mnesia.Query.write(updated_post)
end

# Delete records
GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.delete(Blog.Post, 1)
end
```

## Table Options

### Attributes

```elixir
use GSMLG.Mnesia.Table,
  attributes: [:id, :field1, :field2],  # Required: List of field names
  type: :set,                            # :set, :ordered_set, or :bag
  index: [:field1],                      # Fields to create indexes on
  autoincrement: false                   # Auto-assign numeric primary keys
```

### Table Types

- **`:set`** (default) - Each record has a unique key
- **`:ordered_set`** - Like set, but records are ordered by key
- **`:bag`** - Multiple records can have the same key

### Storage Types

- **`:ram_copies`** - Table stored in RAM only (fast, not persistent)
- **`:disc_copies`** - Table stored in RAM and on disk (persistent, fast reads)
- **`:disc_only_copies`** - Table stored on disk only (persistent, slower)

```elixir
# Create table with specific storage type
GSMLG.Mnesia.Table.create!(MyTable,
  disc_copies: [node()],
  ram_copies: [:"worker@host"]
)
```

## Query Operations

GSMLG.Mnesia provides three query methods with increasing complexity:

### 1. Simple Queries

```elixir
GSMLG.Mnesia.transaction! fn ->
  # Read by primary key
  GSMLG.Mnesia.Query.read(Blog.Post, 1)

  # Get all records
  GSMLG.Mnesia.Query.all(Blog.Post)

  # Write record
  GSMLG.Mnesia.Query.write(%Blog.Post{title: "New Post", ...})

  # Delete by key
  GSMLG.Mnesia.Query.delete(Blog.Post, 1)

  # Delete specific record
  GSMLG.Mnesia.Query.delete_record(post)
end
```

### 2. Pattern Matching

Use tuples with `:_` wildcards:

```elixir
GSMLG.Mnesia.transaction! fn ->
  # Get all posts by author_id 5
  # Pattern: {id, title, content, author_id, published_at}
  GSMLG.Mnesia.Query.match(Blog.Post, {:_, :_, :_, 5, :_})

  # Get all posts with specific title
  GSMLG.Mnesia.Query.match(Blog.Post, {:_, "My Title", :_, :_, :_})
end
```

### 3. Guard-based Selection (Recommended)

Most powerful and user-friendly:

```elixir
GSMLG.Mnesia.transaction! fn ->
  # Get all posts by a specific author
  GSMLG.Mnesia.Query.select(Blog.Post, {:==, :author_id, 5})

  # Get posts published after a date
  date = ~U[2024-01-01 00:00:00Z]
  GSMLG.Mnesia.Query.select(Blog.Post, {:>, :published_at, date})

  # Complex queries with multiple conditions
  guards = [
    {:==, :author_id, 5},
    {:>, :published_at, date}
  ]
  GSMLG.Mnesia.Query.select(Blog.Post, guards)

  # Nested logical operators
  guards = {:and,
    {:==, :author_id, 5},
    {:or,
      {:==, :title, "First Post"},
      {:==, :title, "Second Post"}
    }
  }
  GSMLG.Mnesia.Query.select(Blog.Post, guards, limit: 10)
end
```

### Available Guard Operators

- **Comparison**: `:==`, `:!=`, `:<`, `:<=`, `:>`, `:>=`
- **Strict**: `:===`, `:!==` (for numbers)
- **Logical**: `:and`, `:or`, `:xor`

### Query Options

```elixir
GSMLG.Mnesia.Query.select(MyTable, guards,
  lock: :read,        # :read, :write, or :sticky_write
  limit: 100,         # Maximum number of results
  coerce: true        # Convert tuples to structs (default: true)
)
```

## Transactions

All query operations must run inside transactions:

```elixir
# Basic transaction
{:ok, result} = GSMLG.Mnesia.transaction(fn ->
  # Your operations here
  GSMLG.Mnesia.Query.read(MyTable, key)
end)

# Transaction with bang (raises on error)
result = GSMLG.Mnesia.transaction!(fn ->
  GSMLG.Mnesia.Query.all(MyTable)
end)

# Transaction with custom retry limit
GSMLG.Mnesia.Transaction.execute(fn ->
  # Operations
end, 5)  # Retry up to 5 times

# Synchronous transaction (waits for all nodes)
GSMLG.Mnesia.Transaction.execute_sync(fn ->
  GSMLG.Mnesia.Query.write(record)
end)

# Abort transaction manually
GSMLG.Mnesia.Transaction.abort(:some_reason)

# Check if inside transaction
GSMLG.Mnesia.Transaction.inside?()
# => true
```

## Distributed Operations

GSMLG.Mnesia is built for distribution from the ground up:

### Adding Nodes

```elixir
# Connect to a specific node
GSMLG.Mnesia.add_nodes(:"app@other_host")

# Connect to multiple nodes
GSMLG.Mnesia.add_nodes([:"app@host1", :"app@host2"])

# Add all connected nodes
GSMLG.Mnesia.add_nodes(Node.list())
```

### Replicating Tables

```elixir
# Create a replica on another node
GSMLG.Mnesia.Table.create_copy(Blog.Post, :"app@host2", :disc_copies)

# Move a table from one node to another
GSMLG.Mnesia.Table.move_copy(Blog.Post, :"app@host1", :"app@host2")

# Delete replica from a node
GSMLG.Mnesia.Table.delete_copy(Blog.Post, :"app@host2")

# Change storage type on a node
GSMLG.Mnesia.Table.set_storage_type(Blog.Post, :"app@host2", :ram_copies)
```

### Waiting for Tables

```elixir
# Wait for tables to be accessible
GSMLG.Mnesia.wait([Blog.Post, Blog.Author])

# Wait with timeout (in milliseconds)
GSMLG.Mnesia.wait([Blog.Post], 5000)

# Wait indefinitely
GSMLG.Mnesia.wait([Blog.Post], :infinity)
```

## Schema Management

```elixir
# Create schema on current node
GSMLG.Mnesia.Schema.create([node()])

# Create schema on multiple nodes
nodes = [node(), :"app@host2", :"app@host3"]
GSMLG.Mnesia.Schema.create(nodes)

# Delete schema
GSMLG.Mnesia.Schema.delete([node()])

# Get schema information
GSMLG.Mnesia.Schema.info()
GSMLG.Mnesia.Schema.info(Blog.Post)

# Change schema storage type
GSMLG.Mnesia.Schema.set_storage_type(node(), :disc_copies)
```

## Table Transformation

Transform table schema when you need to add/remove/modify attributes:

```elixir
# Add a new :tags attribute to existing posts
transform_fun = fn {Blog.Post, id, title, content, author_id, published_at} ->
  {Blog.Post, id, title, content, author_id, published_at, []}  # Add empty tags list
end

new_attributes = [:id, :title, :content, :author_id, :published_at, :tags]

GSMLG.Mnesia.Table.transform(Blog.Post, transform_fun, new_attributes)
```

## Autoincrement Primary Keys

For `:ordered_set` tables, you can enable automatic primary key assignment:

```elixir
defmodule Blog.Comment do
  use GSMLG.Mnesia.Table,
    attributes: [:id, :post_id, :content],
    type: :ordered_set,
    autoincrement: true
end

# Create table
GSMLG.Mnesia.Table.create!(Blog.Comment)

# Write without specifying ID
GSMLG.Mnesia.transaction! fn ->
  comment = GSMLG.Mnesia.Query.write(%Blog.Comment{
    id: nil,  # Will be auto-assigned
    post_id: 1,
    content: "Great post!"
  })

  # comment.id will be automatically set to 1, 2, 3, etc.
end
```

## System Information

```elixir
# Get all system information
GSMLG.Mnesia.system()

# Get specific system info
GSMLG.Mnesia.system(:running_db_nodes)
GSMLG.Mnesia.system(:tables)
GSMLG.Mnesia.system(:transaction_commits)

# Get table information
GSMLG.Mnesia.Table.info(Blog.Post)
GSMLG.Mnesia.Table.info(Blog.Post, :size)
GSMLG.Mnesia.Table.info(Blog.Post, :memory)

# Print info to console
GSMLG.Mnesia.info()
```

## Error Handling

```elixir
# Using safe versions
case GSMLG.Mnesia.transaction(fn ->
  GSMLG.Mnesia.Query.read(Blog.Post, 1)
end) do
  {:ok, post} ->
    IO.inspect(post)
  {:error, reason} ->
    IO.puts("Transaction failed: #{inspect(reason)}")
end

# Using bang versions (raises exceptions)
try do
  GSMLG.Mnesia.transaction! fn ->
    GSMLG.Mnesia.Query.read(Blog.Post, 1)
  end
rescue
  e in GSMLG.Mnesia.TransactionAborted ->
    IO.puts("Transaction aborted: #{e.message}")
  e in GSMLG.Mnesia.Error ->
    IO.puts("Mnesia error: #{e.message}")
end
```

## Production Best Practices

### 1. Always Create Schema for Persistence

```elixir
# In your application start
def start(_type, _args) do
  # Stop mnesia if running
  :mnesia.stop()

  # Create schema on disk
  case GSMLG.Mnesia.Schema.create([node()]) do
    :ok -> :ok
    {:error, {_, {:already_exists, _}}} -> :ok
    error -> error
  end

  # Start mnesia
  GSMLG.Mnesia.start()

  # Create tables with disc_copies
  create_tables()

  # Continue with supervision tree
  # ...
end
```

### 2. Use Disc Copies for Important Data

```elixir
defp create_tables do
  tables = [Blog.Post, Blog.Author, Blog.Comment]

  Enum.each(tables, fn table ->
    case GSMLG.Mnesia.Table.create(table, disc_copies: [node()]) do
      :ok ->
        Logger.info("Created table: #{inspect(table)}")
      {:error, {:already_exists, _}} ->
        :ok
      {:error, reason} ->
        Logger.error("Failed to create table #{inspect(table)}: #{inspect(reason)}")
    end
  end)

  GSMLG.Mnesia.wait(tables, :infinity)
end
```

### 3. Handle Node Discovery

```elixir
# When a new node connects
def handle_node_connect(node) do
  # Add the node to mnesia cluster
  GSMLG.Mnesia.add_nodes([node])

  # Create replicas on the new node
  tables = [Blog.Post, Blog.Author]

  Enum.each(tables, fn table ->
    GSMLG.Mnesia.Table.create_copy(table, node, :ram_copies)
  end)
end
```

### 4. Use Appropriate Lock Types

```elixir
# Read lock for reading (allows concurrent reads)
GSMLG.Mnesia.Query.read(Blog.Post, id, lock: :read)

# Write lock for modifications (exclusive)
GSMLG.Mnesia.Query.write(post, lock: :write)

# Sticky write lock for frequent updates on same node
GSMLG.Mnesia.Query.write(post, lock: :sticky_write)
```

### 5. Batch Operations in Transactions

```elixir
# Good: Single transaction for multiple operations
GSMLG.Mnesia.transaction! fn ->
  posts = GSMLG.Mnesia.Query.select(Blog.Post, {:==, :author_id, 5})
  Enum.each(posts, fn post ->
    updated = %{post | published_at: DateTime.utc_now()}
    GSMLG.Mnesia.Query.write(updated)
  end)
end

# Bad: Multiple transactions
posts |> Enum.each(fn post ->
  GSMLG.Mnesia.transaction! fn ->
    GSMLG.Mnesia.Query.write(post)
  end
end)
```

## Performance Considerations

- **Indexes**: Add indexes to fields you frequently query on
- **Table Types**: Use `:ordered_set` for range queries, `:set` for key lookups
- **Storage**: `:ram_copies` is fastest, `:disc_copies` is balanced, `:disc_only_copies` for large data
- **Locks**: Use `:read` locks when possible to allow concurrent access
- **Distribution**: Replicate read-heavy tables, centralize write-heavy tables
- **Transactions**: Keep transactions short and focused
- **Batch**: Batch multiple operations in single transactions

## Comparison with Other Options

### vs. Ecto + PostgreSQL

- **GSMLG.Mnesia**: Embedded, distributed, no external dependencies, eventual consistency
- **Ecto**: External DB, centralized, ACID guarantees, SQL power

Use GSMLG.Mnesia when:
- You need embedded database without external services
- Distribution and availability are more important than consistency
- Working with Elixir-native data structures
- Building distributed Elixir systems (Phoenix PubSub, session stores, caches)

### vs. ETS

- **GSMLG.Mnesia**: Persistent, distributed, transactional, schema-based
- **ETS**: In-memory only, single-node, no transactions, lower overhead

Use GSMLG.Mnesia when:
- You need persistence across restarts
- You need distribution across nodes
- You need transaction support
- You want structured schema definitions

## Common Use Cases

### 1. Distributed Session Store

```elixir
defmodule App.Session do
  use GSMLG.Mnesia.Table,
    attributes: [:session_id, :user_id, :data, :expires_at],
    type: :set
end

# Create on all nodes
GSMLG.Mnesia.Table.create!(App.Session, ram_copies: Node.list([:visible]))
```

### 2. Configuration Store

```elixir
defmodule App.Config do
  use GSMLG.Mnesia.Table,
    attributes: [:key, :value, :updated_at],
    type: :set
end

GSMLG.Mnesia.Table.create!(App.Config, disc_copies: [node()])
```

### 3. Distributed Cache

```elixir
defmodule App.Cache do
  use GSMLG.Mnesia.Table,
    attributes: [:key, :value, :ttl],
    type: :set
end

def get(key) do
  GSMLG.Mnesia.transaction!(fn ->
    case GSMLG.Mnesia.Query.read(App.Cache, key) do
      nil -> nil
      entry ->
        if DateTime.compare(entry.ttl, DateTime.utc_now()) == :gt do
          entry.value
        else
          GSMLG.Mnesia.Query.delete(App.Cache, key)
          nil
        end
    end
  end)
end
```

### 4. Event Log

```elixir
defmodule App.EventLog do
  use GSMLG.Mnesia.Table,
    attributes: [:id, :event_type, :data, :timestamp],
    type: :ordered_set,
    autoincrement: true,
    index: [:event_type]
end
```

## Testing

```elixir
# In test/test_helper.exs
:mnesia.stop()
:mnesia.delete_schema([node()])
:mnesia.start()

# In your tests
defmodule Blog.PostTest do
  use ExUnit.Case

  setup do
    :mnesia.clear_table(Blog.Post)
    :ok
  end

  test "creates a post" do
    result = GSMLG.Mnesia.transaction! fn ->
      GSMLG.Mnesia.Query.write(%Blog.Post{
        title: "Test Post",
        content: "Content"
      })
    end

    assert result.id != nil
    assert result.title == "Test Post"
  end
end
```

## Migration from Other Solutions

### From ETS

Replace ETS calls with GSMLG.Mnesia transactions:

```elixir
# Before (ETS)
:ets.insert(:my_table, {key, value})
:ets.lookup(:my_table, key)

# After (GSMLG.Mnesia)
GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.write(%MyTable{key: key, value: value})
end

GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.read(MyTable, key)
end
```

### From Ecto

```elixir
# Before (Ecto)
Repo.insert(%Post{title: "Title"})
Repo.get(Post, 1)
Repo.all(Post)

# After (GSMLG.Mnesia)
GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.write(%Blog.Post{title: "Title"})
end

GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.read(Blog.Post, 1)
end

GSMLG.Mnesia.transaction! fn ->
  GSMLG.Mnesia.Query.all(Blog.Post)
end
```

## Troubleshooting

### Schema Already Exists

```elixir
# Solution: Delete and recreate, or just start Mnesia
:mnesia.stop()
:mnesia.delete_schema([node()])
:mnesia.create_schema([node()])
:mnesia.start()
```

### Table Not Found

```elixir
# Ensure table is created
GSMLG.Mnesia.Table.create!(YourTable)

# Wait for it to be ready
GSMLG.Mnesia.wait([YourTable], :infinity)
```

### Transaction Aborted

Check for:
- Deadlocks (use simpler lock patterns)
- Schema conflicts (ensure all nodes have same schema)
- Resource exhaustion (check disk space, memory)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License

## Resources

- [Erlang Mnesia Documentation](http://erlang.org/doc/man/mnesia.html)
- [Mnesia User's Guide](http://erlang.org/doc/apps/mnesia/Mnesia_chap1.html)
- [GSMLG Umbrella Project](https://github.com/gsmlg-dev/gsmlg_umbrella)

## Changelog

### 0.1.1 (Current)

- Comprehensive documentation
- Production-ready with 109 passing tests
- Full Mnesia feature coverage
- Autoincrement support
- Distributed operations
- Transaction management
- Multiple query interfaces
