defmodule GSMLG.GaoNote.Sync.SelectorsTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.Compat.LabelSelector
  alias GSMLG.GaoNote.Sync.Selectors

  defp vectors do
    Path.expand("../../../fixtures/sync/selector-vectors-v1.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  test "portable regexes match the independently expected cross-language vectors" do
    for vector <- vectors()["accepted_regex"] do
      assert {:ok, [condition]} = Selectors.parse("project~=" <> vector["pattern"])

      for %{"value" => value, "matches" => expected} <- vector["cases"] do
        label = %{key: "project", value: value, value_type: "text"}

        assert LabelSelector.matches?(label, condition) == expected,
               "#{vector["name"]}: #{inspect(vector["pattern"])} against #{inspect(value)}"
      end
    end
  end

  test "nonportable regex syntax is rejected before authorization" do
    for pattern <- vectors()["rejected_regex"] do
      assert {:error, :unsupported_sync_regex} = Selectors.parse("project~=" <> pattern),
             "unexpectedly accepted regex #{inspect(pattern)}"
    end
  end

  test "Unicode exact selectors keep their existing semantics" do
    for vector <- vectors()["exact_selectors"] do
      assert {:ok, [condition]} = Selectors.parse(vector["selector"])

      for %{"value" => value, "matches" => expected} <- vector["cases"] do
        assert LabelSelector.matches?(%{key: "project", value: value}, condition) == expected
      end
    end
  end
end
