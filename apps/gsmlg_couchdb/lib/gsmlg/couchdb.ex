defmodule GSMLG.CouchDB do
  @moduledoc """
  Elixir HTTP client for Apache CouchDB with persistent connections.

  GSMLG.CouchDB provides a complete interface to Apache CouchDB's HTTP API
  using Mint for persistent HTTP/1.1 connections. The client manages a single
  GenServer connection process that handles request/response correlation
  and basic authentication.

  ## Features

  - Persistent HTTP/1.1 connections via Mint
  - Complete CouchDB API coverage (databases, documents, queries, indexes, attachments)
  - Mango query support with full selector syntax
  - Bulk operations for efficient batch processing
  - Built-in basic authentication
  - Optional telemetry integration
  - Consistent error handling with `{:ok, result}` / `{:error, reason}` tuples

  ## Modules

  - `GSMLG.CouchDB.Connection` - HTTP connection management via GenServer
  - `GSMLG.CouchDB.DB` - Database operations (create, delete, compact, security)
  - `GSMLG.CouchDB.Docs` - Document operations (CRUD, queries, indexes, attachments)
  - `GSMLG.CouchDB.Node` - Node-level operations

  ## Quick Start

      # Configure connection
      config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
        scheme: :http,
        host: "localhost",
        port: 5984,
        username: "admin",
        password: "password"

      # Use the API
      alias GSMLG.CouchDB.{DB, Docs}

      DB.create_db("myapp")
      Docs.create_doc("myapp", %{type: "user", name: "Alice"})
      Docs.find("myapp", %{selector: %{type: "user"}})

  See the README for comprehensive documentation and examples.
  """
end
