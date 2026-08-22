defmodule GSMLG.Web.OpenApi.OperationTest do
  use ExUnit.Case, async: true

  alias GSMLG.Web.OpenApi.{Operation, Operations}

  test "requires every operation to declare its security" do
    assert_raise KeyError, fn ->
      Operation.operation("operationId", "Tag", "Summary", %{})
    end
  end

  test "rejects duplicate verbs for the same OpenAPI path" do
    assert_raise ArgumentError, "duplicate OpenAPI operation get for /api/gao_notes", fn ->
      Operations.deep_merge_paths(
        %{"/api/gao_notes" => %{"get" => %{"operationId" => "listGaoNotes"}}},
        %{"/api/gao_notes" => %{"get" => %{"operationId" => "duplicateListGaoNotes"}}}
      )
    end
  end
end
