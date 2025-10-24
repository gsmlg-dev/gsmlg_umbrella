ExUnit.start()

# Note: PKI tests require CouchDB to be running on localhost:5984
# If CouchDB is not available, tests will fail with connection errors
# To run tests, ensure CouchDB is running:
#   docker run -d -p 5984:5984 -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=password couchdb:latest
#
# Or skip integration tests and only run unit tests:
#   mix test --exclude integration
