defmodule GSMLG.CouchDBTest do
  use ExUnit.Case

  describe "GSMLG.CouchDB" do
    test "module is loaded and documented" do
      # The module provides CouchDB HTTP client documentation
      assert Code.ensure_loaded?(GSMLG.CouchDB)
      assert {:docs_v1, _, _, _, %{"en" => _doc}, _, _} = Code.fetch_docs(GSMLG.CouchDB)
    end

    test "submodules are available" do
      # Core submodules should be loadable
      assert Code.ensure_loaded?(GSMLG.CouchDB.Connection)
      assert Code.ensure_loaded?(GSMLG.CouchDB.DB)
      assert Code.ensure_loaded?(GSMLG.CouchDB.Docs)
      assert Code.ensure_loaded?(GSMLG.CouchDB.Node)
    end
  end
end
