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

    documented_operations =
      paths
      |> Enum.flat_map(fn {path, verbs} ->
        Enum.map(verbs, fn {verb, _operation} -> {verb, route_shape(path)} end)
      end)
      |> MapSet.new()

    inventory_operations =
      inventory["endpoints"]
      |> Enum.filter(&(&1["scope"] == "Note"))
      |> MapSet.new(fn endpoint ->
        path = endpoint["openapi_path"] || endpoint["path"]
        {String.downcase(endpoint["method"]), route_shape(path)}
      end)

    assert documented_operations == inventory_operations
    assert MapSet.size(inventory_operations) == 24
    assert Enum.sum(Enum.map(paths, fn {_, verbs} -> map_size(verbs) end)) == 24
    refute get_in(paths, ["/api/notes/{id}", "patch"])
    assert %OpenApiSpex.OpenApi{} = GSMLG.Web.ApiSpec.spec()
  end

  defp route_shape(path), do: String.replace(path, ~r/\{[^}]+\}/, "{}")
end
