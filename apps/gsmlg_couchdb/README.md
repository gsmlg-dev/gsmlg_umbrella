# GSMLG.CouchDB

**Elixir HTTP client for Apache CouchDB with persistent connections and built-in telemetry**

GSMLG.CouchDB is a lightweight, production-ready HTTP client for Apache CouchDB built on top of Mint for HTTP/1.1 persistent connections. It provides a clean Elixir API for all CouchDB operations including databases, documents, Mango queries, indexes, and attachments.

## Features

- **Persistent HTTP/1.1 connections** - Single GenServer manages connection lifecycle
- **Complete CouchDB API coverage** - Databases, documents, queries, indexes, attachments
- **Mango query support** - Declarative JSON querying with full parameter support
- **Bulk operations** - Efficient batch document operations
- **Basic authentication** - Built-in username/password auth
- **Telemetry integration** - Optional observability with GSMLG.Telemetry
- **Error handling** - Consistent error tuples for all operations
- **Type-safe API** - Full typespec coverage

## What is CouchDB?

Apache CouchDB is a document-oriented NoSQL database that uses JSON for documents, JavaScript for MapReduce indexes, and HTTP for its API. CouchDB is known for:

- **Schema-free** - Store any JSON document structure
- **ACID semantics** - Eventual consistency with MVCC
- **RESTful HTTP API** - All operations via HTTP
- **Replication** - Multi-master synchronization
- **MapReduce views** - JavaScript-based indexing
- **Mango queries** - Declarative JSON query language

## Installation

Add `gsmlg_couchdb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_couchdb, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure the CouchDB connection in `config/config.exs`:

```elixir
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :http,
  host: "localhost",
  port: 5984,
  username: "admin",
  password: "password"
```

**Configuration options:**
- `:scheme` - `:http` or `:https` (default: `:http`)
- `:host` - CouchDB server hostname (default: `"localhost"`)
- `:port` - CouchDB server port (default: `5984`)
- `:username` - Admin username for authentication
- `:password` - Admin password for authentication

**Environment-based configuration:**

```elixir
# config/dev.exs
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :http,
  host: "localhost",
  port: 5984,
  username: "admin",
  password: "admin"

# config/prod.exs
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :https,
  host: System.get_env("COUCHDB_HOST") || "couchdb.example.com",
  port: String.to_integer(System.get_env("COUCHDB_PORT") || "6984"),
  username: System.fetch_env!("COUCHDB_USERNAME"),
  password: System.fetch_env!("COUCHDB_PASSWORD")
```

## Quick Start

```elixir
alias GSMLG.CouchDB.{DB, Docs}

# List all databases
{:ok, dbs} = DB.all_dbs()
#=> ["_replicator", "_users", "mydb"]

# Create a database
{:ok, _} = DB.create_db("myapp")

# Create a document
{:ok, result} = Docs.create_doc("myapp", %{
  type: "user",
  name: "Alice",
  email: "alice@example.com"
})
#=> %{id: "abc123", ok: true, rev: "1-xyz"}

# Get a document
{:ok, doc} = Docs.get_doc("myapp", "abc123")
#=> %{_id: "abc123", _rev: "1-xyz", type: "user", name: "Alice", ...}

# Update a document
{:ok, _} = Docs.put_doc("myapp", "abc123", %{
  _rev: "1-xyz",
  type: "user",
  name: "Alice Smith",
  email: "alice@example.com"
})

# Query documents with Mango
{:ok, results} = Docs.find("myapp", %{
  selector: %{type: "user"},
  limit: 10
})

# Delete a document
{:ok, _} = Docs.delete_doc("myapp", "abc123?rev=2-abc")
```

## Usage

### Database Operations

#### List All Databases

```elixir
alias GSMLG.CouchDB.DB

# List all databases
DB.all_dbs()
#=> ["_replicator", "_users", "myapp", "logs"]
```

#### Create Database

```elixir
# Create a new database
DB.create_db("myapp")
#=> %{ok: true}

# Database names must:
# - Start with a lowercase letter
# - Contain only: a-z, 0-9, _, $, (, ), +, -, /
```

#### Get Database Info

```elixir
DB.info_db("myapp")
#=> %{
#     db_name: "myapp",
#     doc_count: 1523,
#     doc_del_count: 45,
#     disk_size: 8675309,
#     ...
#   }
```

#### Delete Database

```elixir
DB.drop_db("old_database")
#=> %{ok: true}

# Warning: This permanently deletes all documents!
```

#### Database Compaction

```elixir
# Compact database (reclaim disk space)
DB.compact("myapp")
#=> %{ok: true}

# Compact specific design document
DB.compact("myapp", "design_doc_id")
#=> %{ok: true}

# Clean up old view files
DB.view_cleanup("myapp")
#=> %{ok: true}
```

#### Database Security

```elixir
# Get security settings
DB.get_security("myapp")
#=> %{admins: %{names: [], roles: []}, members: %{names: [], roles: []}}

# Set security (restrict to authenticated users)
DB.put_security("myapp", %{
  admins: %{
    names: ["admin"],
    roles: ["admin"]
  },
  members: %{
    names: [],
    roles: ["user"]
  }
})
#=> %{ok: true}
```

### Document Operations

#### Create Documents

```elixir
alias GSMLG.CouchDB.Docs

# Create document (CouchDB generates ID)
Docs.create_doc("myapp", %{
  type: "post",
  title: "Hello World",
  body: "This is my first post",
  published_at: "2024-01-15T10:00:00Z"
})
#=> %{id: "generated-uuid", ok: true, rev: "1-abc123"}

# Create document with specific ID
Docs.put_doc("myapp", "post-001", %{
  type: "post",
  title: "Hello World"
})
#=> %{id: "post-001", ok: true, rev: "1-xyz789"}
```

#### Read Documents

```elixir
# Get document by ID
Docs.get_doc("myapp", "post-001")
#=> %{
#     _id: "post-001",
#     _rev: "1-xyz789",
#     type: "post",
#     title: "Hello World"
#   }

# Get all documents (IDs and revisions only)
Docs.all_docs("myapp")
#=> %{
#     total_rows: 100,
#     offset: 0,
#     rows: [
#       %{id: "post-001", key: "post-001", value: %{rev: "1-xyz"}},
#       ...
#     ]
#   }

# Get all documents with content
Docs.all_docs("myapp", %{include_docs: true})
#=> %{rows: [%{doc: %{_id: "post-001", ...}}, ...]}
```

#### Update Documents

```elixir
# Update requires current revision
Docs.put_doc("myapp", "post-001", %{
  _rev: "1-xyz789",
  type: "post",
  title: "Hello World - Updated",
  updated_at: "2024-01-16T10:00:00Z"
})
#=> %{id: "post-001", ok: true, rev: "2-newrev"}

# Conflict error if revision doesn't match
Docs.put_doc("myapp", "post-001", %{
  _rev: "1-oldrev",
  title: "This will fail"
})
#=> {:error, %{error: "conflict", reason: "Document update conflict"}}
```

#### Delete Documents

```elixir
# Delete requires revision
Docs.delete_doc("myapp", "post-001?rev=2-newrev")
#=> %{id: "post-001", ok: true, rev: "3-deleted"}

# Or pass revision as parameter
Docs.delete_doc("myapp", "post-001", %{rev: "2-newrev"})
#=> %{id: "post-001", ok: true, rev: "3-deleted"}
```

#### Copy Documents

```elixir
# Copy document to new ID
Docs.copy_doc("myapp", "post-001", "post-001-backup")
#=> %{id: "post-001-backup", ok: true, rev: "1-copied"}
```

### Bulk Operations

```elixir
# Bulk create/update documents
Docs.bulk_docs("myapp", [
  %{_id: "doc1", type: "user", name: "Alice"},
  %{_id: "doc2", type: "user", name: "Bob"},
  %{_id: "doc3", type: "user", name: "Charlie"}
])
#=> [
#     %{id: "doc1", ok: true, rev: "1-abc"},
#     %{id: "doc2", ok: true, rev: "1-def"},
#     %{id: "doc3", ok: true, rev: "1-ghi"}
#   ]

# Bulk get documents
Docs.bulk_get("myapp", [
  %{id: "doc1"},
  %{id: "doc2"},
  %{id: "doc3"}
])
#=> %{results: [...]}
```

### Mango Queries

Mango is CouchDB's declarative JSON query language, similar to MongoDB queries.

#### Basic Queries

```elixir
# Find all users
Docs.find("myapp", %{
  selector: %{type: "user"}
})
#=> %{docs: [...], bookmark: "...", warning: nil}

# Find users with specific email domain
Docs.find("myapp", %{
  selector: %{
    type: "user",
    email: %{"$regex": ".*@example\\.com$"}
  }
})

# Find with comparison operators
Docs.find("myapp", %{
  selector: %{
    type: "post",
    published_at: %{
      "$gte": "2024-01-01",
      "$lt": "2024-02-01"
    }
  }
})
```

#### Query Options

```elixir
# Limit and skip (pagination)
Docs.find("myapp", %{
  selector: %{type: "user"},
  limit: 20,
  skip: 40  # Page 3 (0-indexed)
})

# Sort results
Docs.find("myapp", %{
  selector: %{type: "post"},
  sort: [%{published_at: "desc"}]
})

# Select specific fields
Docs.find("myapp", %{
  selector: %{type: "user"},
  fields: ["_id", "name", "email"]
})

# Use specific index
Docs.find("myapp", %{
  selector: %{type: "user", status: "active"},
  use_index: ["_design/users", "by_status"]
})

# Get execution statistics
Docs.find("myapp", %{
  selector: %{type: "user"},
  execution_stats: true
})
#=> %{
#     docs: [...],
#     execution_stats: %{
#       total_keys_examined: 100,
#       total_docs_examined: 50,
#       results_returned: 25,
#       execution_time_ms: 12.5
#     }
#   }
```

#### Pagination with Bookmarks

```elixir
# First page
{:ok, page1} = Docs.find("myapp", %{
  selector: %{type: "user"},
  limit: 25
})

bookmark = page1.bookmark

# Next page using bookmark
Docs.find("myapp", %{
  selector: %{type: "user"},
  limit: 25,
  bookmark: bookmark
})
```

#### Selector Operators

```elixir
# Comparison: $lt, $lte, $gt, $gte, $eq, $ne
%{age: %{"$gte": 18, "$lt": 65}}

# Logical: $and, $or, $not, $nor
%{
  "$or": [
    %{status: "active"},
    %{priority: "high"}
  ]
}

# Existence: $exists
%{profile_picture: %{"$exists": true}}

# Type checking: $type
%{score: %{"$type": "number"}}

# In array: $in, $nin
%{status: %{"$in": ["active", "pending"]}}

# Array: $all, $elemMatch, $size
%{tags: %{"$all": ["elixir", "couchdb"]}}

# String: $regex
%{email: %{"$regex": ".*@company\\.com$"}}
```

### Indexes

Indexes improve query performance by pre-computing sorted document lists.

#### Create Index

```elixir
# Create simple index
Docs.create_index("myapp", %{
  index: %{
    fields: ["type", "published_at"]
  },
  name: "type-published-idx",
  type: "json"
})
#=> %{id: "_design/abc123", name: "type-published-idx", result: "created"}

# Create compound index
Docs.create_index("myapp", %{
  index: %{
    fields: [
      %{name: "status"},
      %{age: "desc"}
    ]
  },
  name: "status-age-idx"
})
```

#### List Indexes

```elixir
Docs.get_index("myapp")
#=> %{
#     total_rows: 3,
#     indexes: [
#       %{ddoc: nil, name: "_all_docs", type: "special"},
#       %{ddoc: "_design/abc123", name: "type-published-idx", type: "json"},
#       ...
#     ]
#   }
```

#### Delete Index

```elixir
Docs.delete_index("myapp", "design_doc_id", "index_name")
#=> %{ok: true}
```

#### Query Explanation

See which index CouchDB will use for a query:

```elixir
Docs.explain_query("myapp", %{
  selector: %{type: "user", status: "active"}
})
#=> %{
#     dbname: "myapp",
#     index: %{
#       ddoc: "_design/users",
#       name: "by_status",
#       type: "json"
#     },
#     selector: %{...},
#     opts: %{...},
#     limit: 25,
#     skip: 0
#   }
```

### Attachments

Store binary files attached to documents.

#### Upload Attachment

```elixir
# Read file
data = File.read!("photo.jpg")

# Attach to document (requires document revision)
Docs.put_attachment(
  "myapp",
  "user-123?rev=2-abc",
  "profile_photo",
  data,
  [{"Content-Type", "image/jpeg"}]
)
#=> %{id: "user-123", ok: true, rev: "3-newrev"}
```

#### Check if Attachment Exists

```elixir
Docs.attachment_exists?("myapp", "user-123", "profile_photo")
#=> true
```

#### Download Attachment

```elixir
{:ok, binary_data} = Docs.get_attachment("myapp", "user-123", "profile_photo")

# Save to file
File.write!("downloaded_photo.jpg", binary_data)
```

#### Delete Attachment

```elixir
Docs.delete_attachment(
  "myapp",
  "user-123?rev=3-newrev",
  "profile_photo"
)
#=> %{id: "user-123", ok: true, rev: "4-deleted"}
```

## Telemetry

GSMLG.CouchDB emits telemetry events for monitoring and observability.

### Events

#### `[:gsmlg, :couchdb, :request, :start]`

Emitted when an HTTP request starts.

**Measurements:** `%{system_time: integer()}`

**Metadata:**
- `:method` - HTTP method ("GET", "POST", etc.)
- `:path` - Request path
- `:database` - Database name (if applicable)

#### `[:gsmlg, :couchdb, :request, :stop]`

Emitted when an HTTP request completes.

**Measurements:**
- `:duration` - Request duration in native time units
- `:monotonic_time` - Monotonic timestamp

**Metadata:**
- `:method` - HTTP method
- `:path` - Request path
- `:status` - HTTP status code
- `:database` - Database name (if applicable)
- `:error` - Error reason (if failed)

#### `[:gsmlg, :couchdb, :connection, :connected]`

Emitted when connection to CouchDB is established.

**Measurements:** `%{system_time: integer()}`

**Metadata:**
- `:host` - CouchDB host
- `:port` - CouchDB port
- `:scheme` - Connection scheme (:http or :https)

### Example Handler

```elixir
:telemetry.attach(
  "couchdb-metrics",
  [:gsmlg, :couchdb, :request, :stop],
  fn event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(
      measurements.duration,
      :native,
      :millisecond
    )

    IO.puts("""
    CouchDB Request:
      Method: #{metadata.method}
      Path: #{metadata.path}
      Status: #{metadata.status}
      Duration: #{duration_ms}ms
    """)
  end,
  nil
)
```

## Connection Model

GSMLG.CouchDB uses a single GenServer to manage a persistent HTTP/1.1 connection via Mint:

**Architecture:**
- Single `GSMLG.CouchDB.Connection` GenServer per application
- Persistent connection with HTTP/1.1 keep-alive
- Automatic request/response correlation
- Basic authentication on every request
- Asynchronous request handling

**Benefits:**
- Connection reuse (no TCP handshake overhead)
- Simple architecture (no connection pool complexity)
- Predictable behavior (serialized requests)

**Trade-offs:**
- Serial request processing (one at a time)
- Single point of failure (connection restart on error)

**For high concurrency:**
- Use external connection pooling (Poolboy, NimblePool)
- Run multiple Connection processes
- Consider CouchDB clustering for horizontal scaling

## Error Handling

All functions return `{:ok, result}` or `{:error, reason}` tuples.

**Common errors:**

```elixir
# Database doesn't exist
{:error, %{error: "not_found", reason: "Database does not exist"}}

# Document doesn't exist
{:error, %{error: "not_found", reason: "missing"}}

# Update conflict (wrong revision)
{:error, %{error: "conflict", reason: "Document update conflict"}}

# Invalid database name
** (RuntimeError) db name invalid

# Unauthorized
{:error, %{error: "unauthorized", reason: "Authentication required"}}

# Connection error
{:error, %Mint.TransportError{reason: :econnrefused}}
```

**Bang variants** raise on error:

```elixir
# These raise exceptions on error
DB.all_dbs!()
Docs.get_doc!("myapp", "doc123")
Docs.put_doc!("myapp", "doc123", %{...})
```

## Production Best Practices

### 1. Use Environment Variables for Credentials

```elixir
# config/releases.exs or config/runtime.exs
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :https,
  host: System.fetch_env!("COUCHDB_HOST"),
  port: String.to_integer(System.get_env("COUCHDB_PORT", "6984")),
  username: System.fetch_env!("COUCHDB_USERNAME"),
  password: System.fetch_env!("COUCHDB_PASSWORD")
```

### 2. Create Indexes for Queries

Always create indexes for fields you query frequently:

```elixir
# Create index before querying
Docs.create_index("myapp", %{
  index: %{fields: ["type", "created_at"]},
  name: "type-created-idx"
})

# Then query will use index
Docs.find("myapp", %{
  selector: %{type: "user"},
  sort: [%{created_at: "desc"}]
})
```

### 3. Use Bulk Operations

Batch operations are much faster than individual calls:

```elixir
# Instead of this:
Enum.each(users, fn user ->
  Docs.create_doc("myapp", user)
end)

# Do this:
Docs.bulk_docs("myapp", users)
```

### 4. Handle Conflicts Gracefully

CouchDB uses optimistic concurrency control:

```elixir
def update_with_retry(db, doc_id, update_fn, retries \\ 3) do
  case Docs.get_doc(db, doc_id) do
    {:ok, doc} ->
      updated = update_fn.(doc)

      case Docs.put_doc(db, doc_id, updated) do
        {:ok, result} ->
          {:ok, result}

        {:error, %{error: "conflict"}} when retries > 0 ->
          # Retry with updated revision
          update_with_retry(db, doc_id, update_fn, retries - 1)

        error ->
          error
      end

    error ->
      error
  end
end
```

### 5. Monitor with Telemetry

Track slow queries and errors:

```elixir
:telemetry.attach(
  "couchdb-slow-query-alert",
  [:gsmlg, :couchdb, :request, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(
      measurements.duration,
      :native,
      :millisecond
    )

    if duration_ms > 1000 do
      Logger.warning("Slow CouchDB query: #{metadata.path} (#{duration_ms}ms)")
    end
  end,
  nil
)
```

## Common Use Cases

### 1. User Management System

```elixir
defmodule MyApp.Users do
  alias GSMLG.CouchDB.Docs

  @db "users"

  def create_user(attrs) do
    user = Map.merge(attrs, %{
      type: "user",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    Docs.create_doc(@db, user)
  end

  def find_by_email(email) do
    case Docs.find(@db, %{
      selector: %{type: "user", email: email},
      limit: 1
    }) do
      {:ok, %{docs: [user]}} -> {:ok, user}
      {:ok, %{docs: []}} -> {:error, :not_found}
      error -> error
    end
  end

  def list_active_users(page \\ 0, per_page \\ 25) do
    Docs.find(@db, %{
      selector: %{type: "user", status: "active"},
      sort: [%{created_at: "desc"}],
      limit: per_page,
      skip: page * per_page
    })
  end
end
```

### 2. Document Versioning

```elixir
defmodule MyApp.Documents do
  alias GSMLG.CouchDB.Docs

  def create_with_history(db, doc_data) do
    # Create main document
    {:ok, result} = Docs.create_doc(db, doc_data)

    # Create history entry
    history = Map.merge(doc_data, %{
      type: "history",
      original_id: result.id,
      version: 1,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    Docs.create_doc(db, history)

    {:ok, result}
  end

  def get_history(db, doc_id) do
    Docs.find(db, %{
      selector: %{type: "history", original_id: doc_id},
      sort: [%{version: "desc"}]
    })
  end
end
```

### 3. Event Sourcing

```elixir
defmodule MyApp.EventStore do
  alias GSMLG.CouchDB.Docs

  @db "events"

  def append_event(aggregate_id, event_type, event_data) do
    event = %{
      type: "event",
      aggregate_id: aggregate_id,
      event_type: event_type,
      data: event_data,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      sequence: get_next_sequence(aggregate_id)
    }

    Docs.create_doc(@db, event)
  end

  def get_events(aggregate_id) do
    Docs.find(@db, %{
      selector: %{type: "event", aggregate_id: aggregate_id},
      sort: [%{sequence: "asc"}]
    })
  end

  defp get_next_sequence(aggregate_id) do
    case get_events(aggregate_id) do
      {:ok, %{docs: events}} -> length(events) + 1
      _ -> 1
    end
  end
end
```

### 4. Full-Text Search with Indexes

```elixir
defmodule MyApp.Search do
  alias GSMLG.CouchDB.Docs

  def setup_search_index(db) do
    Docs.create_index(db, %{
      index: %{
        fields: ["type", "title", "body", "tags"]
      },
      name: "content-search-idx"
    })
  end

  def search_posts(query) do
    Docs.find("blog", %{
      selector: %{
        type: "post",
        "$or": [
          %{title: %{"$regex": "(?i)#{query}"}},
          %{body: %{"$regex": "(?i)#{query}"}},
          %{tags: %{"$elemMatch": %{"$regex": "(?i)#{query}"}}}
        ]
      },
      limit: 50
    })
  end
end
```

### 5. Multi-Tenant Application

```elixir
defmodule MyApp.Tenants do
  alias GSMLG.CouchDB.{DB, Docs}

  def create_tenant(tenant_id) do
    db_name = "tenant_#{tenant_id}"

    with {:ok, _} <- DB.create_db(db_name),
         {:ok, _} <- setup_indexes(db_name),
         {:ok, _} <- setup_security(db_name, tenant_id) do
      {:ok, db_name}
    end
  end

  defp setup_indexes(db_name) do
    Docs.create_index(db_name, %{
      index: %{fields: ["type", "created_at"]},
      name: "type-created-idx"
    })
  end

  defp setup_security(db_name, tenant_id) do
    DB.put_security(db_name, %{
      admins: %{names: [], roles: ["admin"]},
      members: %{names: [], roles: ["tenant_#{tenant_id}"]}
    })
  end
end
```

## Troubleshooting

### Connection refused

**Error:** `{:error, %Mint.TransportError{reason: :econnrefused}}`

**Causes:**
1. CouchDB is not running
2. Wrong host/port configuration
3. Firewall blocking connection

**Solutions:**
```bash
# Check if CouchDB is running
curl http://localhost:5984/

# Check configuration
iex> Application.get_env(:gsmlg_couchdb, GSMLG.CouchDB.Connection)
```

### Authentication required

**Error:** `{:error, %{error: "unauthorized"}}`

**Causes:**
1. Missing username/password in config
2. Incorrect credentials
3. CouchDB requires authentication

**Solutions:**
```elixir
# Verify credentials in config
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  username: "admin",
  password: "correct_password"
```

### Database does not exist

**Error:** `{:error, %{error: "not_found", reason: "Database does not exist"}}`

**Solutions:**
```elixir
# Create database first
GSMLG.CouchDB.DB.create_db("myapp")
```

### Document update conflict

**Error:** `{:error, %{error: "conflict"}}`

**Causes:**
1. Document revision doesn't match current
2. Another process updated the document

**Solutions:**
```elixir
# Get current revision
{:ok, doc} = Docs.get_doc("myapp", "doc123")

# Update with current revision
Docs.put_doc("myapp", "doc123", Map.put(doc, :field, "new_value"))
```

### Invalid database name

**Error:** `** (RuntimeError) db name invalid`

**Causes:**
- Database name doesn't follow CouchDB rules

**Solutions:**
```elixir
# Valid names (must start with lowercase letter)
"mydb"        # ✓
"my_db_123"   # ✓
"app-prod"    # ✓

# Invalid names
"MyDB"        # ✗ (uppercase)
"123db"       # ✗ (starts with number)
"my.db"       # ✗ (contains period)
```

## Comparison with Alternatives

| Feature | GSMLG.CouchDB | Couchex | Raw HTTP |
|---------|---------------|---------|----------|
| **Connection** | Persistent (Mint) | Per-request | Per-request |
| **API Style** | Function-based | Function-based | Manual |
| **Auth** | Built-in Basic | Built-in | Manual headers |
| **Telemetry** | Built-in | None | Manual |
| **Dependencies** | Jason, Mint | HTTPoison, Jason | HTTPoison |
| **Complexity** | Low | Low | High |
| **Performance** | High (persistent) | Medium | Low-Medium |

**When to use GSMLG.CouchDB:**
- Need persistent connections for better performance
- Want built-in telemetry and monitoring
- Prefer lightweight dependencies (Mint vs HTTPoison)
- Need production-ready client with good defaults

**When to use alternatives:**
- Need specific features only in other clients
- Already using HTTPoison ecosystem
- Have custom requirements not met by this client

## Resources

- [Apache CouchDB Documentation](https://docs.couchdb.org/)
- [CouchDB Guide](http://guide.couchdb.org/)
- [Mango Query Language](https://docs.couchdb.org/en/stable/api/database/find.html)
- [CouchDB Best Practices](https://docs.couchdb.org/en/stable/best-practices/index.html)
- [HTTP API Reference](https://docs.couchdb.org/en/stable/api/index.html)

## License

MIT License - see LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Submit a pull request
