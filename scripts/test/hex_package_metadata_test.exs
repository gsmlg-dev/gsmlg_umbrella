ExUnit.start()
Code.require_file("../lib/release/hex_packages.ex", __DIR__)

defmodule GSMLG.Release.HexPackageMetadataTest do
  use ExUnit.Case

  alias GSMLG.Release.HexPackages

  @version "2.3.4"

  setup do
    Mix.start()
    previous_env = Mix.env()
    root = Path.join(System.tmp_dir!(), "hex-metadata-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_mix(root, unique_app("umbrella"), @version, apps_path: "apps")

    on_exit(fn ->
      Mix.env(previous_env)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "only projects explicitly declaring package metadata opt in", %{root: root} do
    published = child(root, "published")
    child(root, "application_only", publish: false)

    assert [%{app: app, name: name, version: @version, deps: []}] =
             HexPackages.discover!(root, @version)

    assert app == Atom.to_string(published)
    assert name == app
  end

  test "an umbrella with no opted-in projects fails explicitly", %{root: root} do
    child(root, "application_only", publish: false)

    assert_raise ArgumentError, ~r/no projects declare Hex package metadata/, fn ->
      HexPackages.discover!(root, @version)
    end
  end

  test "every child must match the requested release version, including unmarked apps", %{
    root: root
  } do
    child(root, "published")
    mismatch = child(root, "application_only", publish: false, version: "0.1.0")

    error =
      assert_raise ArgumentError, fn ->
        HexPackages.discover!(root, @version)
      end

    assert error.message =~ "apps/#{mismatch}/mix.exs"
    assert error.message =~ "version 0.1.0, expected #{@version}"
  end

  test "the root version must match the requested release version", %{root: root} do
    child(root, "published")
    write_mix(root, unique_app("root_mismatch"), "0.9.0", apps_path: "apps")

    assert_raise ArgumentError, ~r/mix.exs: version 0.9.0, expected 2.3.4/, fn ->
      HexPackages.discover!(root, @version)
    end
  end

  test "all listed archive assets must exist before discovery succeeds", %{root: root} do
    app = child(root, "missing_asset")
    File.rm!(Path.join([root, "apps", Atom.to_string(app), "LICENSE"]))

    assert_raise ArgumentError, ~r/package file LICENSE does not exist/, fn ->
      HexPackages.discover!(root, @version)
    end
  end

  test "description and license metadata are required", %{root: root} do
    for options <- [[description: ""], [licenses: []]] do
      fixture_root = Path.join(root, "invalid_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fixture_root)
      write_mix(fixture_root, unique_app("umbrella"), @version, apps_path: "apps")
      child(fixture_root, "invalid_metadata", options)

      assert_raise ArgumentError, ~r/description, licenses and package files are required/, fn ->
        HexPackages.discover!(fixture_root, @version)
      end
    end
  end

  test "internal dependencies need an exact release requirement", %{root: root} do
    for requirement <- [nil, "~> 2.3", ">= 2.3.4", "2.3.3"] do
      fixture_root = Path.join(root, "requirement_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fixture_root)
      write_mix(fixture_root, unique_app("umbrella"), @version, apps_path: "apps")
      dependency = child(fixture_root, "dependency")

      declaration =
        if requirement,
          do: {dependency, requirement, in_umbrella: true},
          else: {dependency, in_umbrella: true}

      child(fixture_root, "dependent", deps: [declaration])

      assert_raise ArgumentError, ~r/must require exact release version 2.3.4/, fn ->
        HexPackages.discover!(fixture_root, @version)
      end
    end
  end

  test "internal production dependencies must themselves opt into Hex", %{root: root} do
    dependency = child(root, "application_only", publish: false)
    child(root, "published", deps: [{dependency, @version, in_umbrella: true}])

    error =
      assert_raise ArgumentError, ~r/not enabled for Hex/, fn ->
        HexPackages.discover!(root, @version)
      end

    assert error.message =~ Atom.to_string(dependency)
  end

  test "exact internal constraints produce dependencies before their dependants", %{root: root} do
    dependency = child(root, "z_dependency")
    middle = child(root, "m_middle", deps: [{dependency, @version, in_umbrella: true}])
    dependent = child(root, "a_dependent", deps: [{middle, @version, in_umbrella: true}])

    assert [first, second, third] = HexPackages.discover!(root, @version)
    assert first.app == Atom.to_string(dependency)
    assert first.deps == []
    assert second.app == Atom.to_string(middle)
    assert second.deps == [first.app]
    assert third.app == Atom.to_string(dependent)
    assert third.deps == [second.app]
  end

  test "production path, git and github dependencies are rejected", %{root: root} do
    for source <- [
          [path: "../some_source"],
          [git: "https://example.invalid/source.git"],
          [github: "example/source"]
        ] do
      fixture_root = Path.join(root, "source_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fixture_root)
      write_mix(fixture_root, unique_app("umbrella"), @version, apps_path: "apps")
      child(fixture_root, "published", deps: [{unique_app("external"), source}])

      assert_raise ArgumentError, ~r/is not a Hex dependency/, fn ->
        HexPackages.discover!(fixture_root, @version)
      end
    end
  end

  test "ordinary Hex requirements retain internal dependency ordering", %{root: root} do
    dependency = child(root, "z_dependency")
    dependent = child(root, "a_dependent", deps: [{dependency, @version}])

    assert [first, second] = HexPackages.discover!(root, @version)
    assert first.app == Atom.to_string(dependency)
    assert second.app == Atom.to_string(dependent)
    assert second.deps == [first.app]
  end

  test "explicit paths to internal packages are rejected", %{root: root} do
    dependency = child(root, "dependency")
    child(root, "dependent", deps: [{dependency, @version, path: "../#{dependency}"}])

    assert_raise ArgumentError, ~r/is not a Hex dependency/, fn ->
      HexPackages.discover!(root, @version)
    end
  end

  test "invalid production Hex version requirements are rejected", %{root: root} do
    child(root, "published", deps: [{unique_app("external"), "not a version requirement"}])

    assert_raise ArgumentError, fn ->
      HexPackages.discover!(root, @version)
    end
  end

  test "dev-only sources and umbrella deps are excluded from the production graph", %{root: root} do
    development_only = child(root, "development_only", publish: false)

    published =
      child(root, "published",
        deps: [
          {unique_app("hex_external"), "~> 1.0"},
          {development_only, in_umbrella: true, only: [:dev, :test]},
          {unique_app("path_external"), path: "../missing", only: :dev},
          {unique_app("git_external"), git: "https://example.invalid/missing.git", only: :test}
        ]
      )

    assert [%{app: app, deps: []}] = HexPackages.discover!(root, @version)
    assert app == Atom.to_string(published)
  end

  defp child(root, label, options \\ []) do
    app = unique_app(label)
    path = Path.join([root, "apps", Atom.to_string(app)])
    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "lib/package.ex"), "# Fixture source\n")
    File.write!(Path.join(path, "LICENSE"), "Fixture license\n")
    File.write!(Path.join(path, "README.md"), "# Fixture package\n")

    config = [deps: options[:deps] || []]

    config =
      if Keyword.get(options, :publish, true) do
        config ++
          [
            description: Keyword.get(options, :description, "Fixture package"),
            package: [
              licenses: Keyword.get(options, :licenses, ["MIT"]),
              files: ["lib", "LICENSE", "README.md", "mix.exs"]
            ]
          ]
      else
        config
      end

    write_mix(path, app, Keyword.get(options, :version, @version), config)
    app
  end

  defp write_mix(path, app, version, config) do
    module = "GSMLG.ReleaseMetadataFixture.Project#{System.unique_integer([:positive])}"

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{module} do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: #{inspect(version)}] ++ #{inspect(config)}
      end
    end
    """)
  end

  defp unique_app(label) do
    String.to_atom("metadata_#{label}_#{System.unique_integer([:positive])}")
  end
end
