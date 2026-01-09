# Check if CouchDB is available
couchdb_available =
  case :gen_tcp.connect(~c"localhost", 5984, [], 1000) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    {:error, _} ->
      false
  end

# Configure ExUnit to exclude CouchDB tests if CouchDB is not available
exclude_tags =
  if couchdb_available do
    []
  else
    IO.puts(
      "\n⚠️  CouchDB not available - excluding :couchdb tests\n" <>
        "   To run all tests, start CouchDB:\n" <>
        "   docker run -d -p 5984:5984 -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=password couchdb:latest\n"
    )

    [:couchdb]
  end

ExUnit.start(exclude: exclude_tags)
