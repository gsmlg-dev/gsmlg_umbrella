defmodule GSMLG.Web.AgentNoteOpenApiTest do
  use ExUnit.Case, async: true

  test "the frozen Note inventory has all 24 operations and no note PATCH" do
    root = Path.expand("../../../../..", __DIR__)

    inventory =
      root
      |> Path.join("docs/reviews/fixtures/gaonote-agent-note-20261008/rest-inventory.json")
      |> File.read!()
      |> Jason.decode!()

    paths = GSMLG.Web.OpenApi.AgentNoteOperations.paths()

    for endpoint <- Enum.filter(inventory["endpoints"], &(&1["scope"] == "Note")) do
      path = endpoint["openapi_path"] || endpoint["path"]

      assert get_in(paths, [path, String.downcase(endpoint["method"])]),
             "missing #{endpoint["method"]} #{path}"
    end

    assert Enum.sum(Enum.map(paths, fn {_, verbs} -> map_size(verbs) end)) == 24
    refute get_in(paths, ["/api/notes/{id}", "patch"])
    assert %OpenApiSpex.OpenApi{} = GSMLG.Web.ApiSpec.spec()
  end
end
