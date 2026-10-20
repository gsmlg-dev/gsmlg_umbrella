Code.require_file("../lib/release/versions.ex", __DIR__)
ExUnit.start()

defmodule GSMLG.Release.VersionsTest do
  use ExUnit.Case, async: true

  alias GSMLG.Release.Versions

  setup do
    root = Path.join(System.tmp_dir!(), "release-versions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "updates root and dynamically discovered children, preserving source", %{root: root} do
    write_project(root, "mix.exs", literal("1.0.0"))
    write_project(root, "apps/first/mix.exs", attribute("0.1.0"))
    write_project(root, "apps/new_child/mix.exs", literal("0.2.0"))
    write_project(root, "deps/external/mix.exs", literal("0.3.0"))

    assert :ok = Versions.update(root, "2.3.4-rc.1+build.7")
    assert File.read!(Path.join(root, "mix.exs")) == literal("2.3.4-rc.1+build.7")
    assert File.read!(Path.join(root, "apps/first/mix.exs")) == attribute("2.3.4-rc.1+build.7")
    assert File.read!(Path.join(root, "apps/new_child/mix.exs")) == literal("2.3.4-rc.1+build.7")
    assert File.read!(Path.join(root, "deps/external/mix.exs")) == literal("0.3.0")
    assert {:ok, "2.3.4-rc.1+build.7"} = Versions.check(root)
  end

  test "check uses root version by default and accepts an explicit version", %{root: root} do
    write_project(root, "mix.exs", attribute("1.0.0"))
    write_project(root, "apps/child/mix.exs", literal("1.0.0"))
    assert {:ok, "1.0.0"} = Versions.check(root)
    assert {:ok, "1.0.0"} = Versions.check(root, "1.0.0")
    assert {:error, message} = Versions.check(root, "2.0.0")
    assert message =~ "mix.exs"
    assert message =~ "expected 2.0.0"
  end

  test "check reports mismatches without modifying any file", %{root: root} do
    write_project(root, "mix.exs", literal("1.0.0"))
    write_project(root, "apps/child/mix.exs", attribute("0.1.0"))
    before = snapshot(root)
    assert {:error, message} = Versions.check(root)
    assert message =~ "apps/child/mix.exs"
    assert message =~ "0.1.0"
    assert snapshot(root) == before
  end

  test "requires strict semantic versions for update and check", %{root: root} do
    write_project(root, "mix.exs", literal("1.0.0"))
    before = snapshot(root)

    for version <- ["1", "1.2", "v1.2.3", "01.2.3", "1.2.3.4", "1.2.3-01", "1.2.3\n"] do
      assert {:error, _} = Versions.update(root, version)
      assert {:error, _} = Versions.check(root, version)
      assert snapshot(root) == before
    end
  end

  test "validates every existing version before editing", %{root: root} do
    write_project(root, "mix.exs", literal("1.0.0"))
    write_project(root, "apps/a_valid/mix.exs", attribute("0.1.0"))
    write_project(root, "apps/z_invalid/mix.exs", literal("invalid"))
    before = snapshot(root)
    assert {:error, message} = Versions.update(root, "2.0.0")
    assert message =~ "apps/z_invalid/mix.exs"
    assert snapshot(root) == before
  end

  test "rejects missing, computed, duplicate, or ambiguous declarations atomically", %{root: root} do
    write_project(root, "mix.exs", literal("1.0.0"))

    for source <- [
          "def project, do: [app: :child]\n",
          "def project, do: [version: System.get_env(\"VERSION\")]\n",
          "def project, do: [version: @version]\n",
          "@version System.get_env(\"VERSION\")\ndef project, do: [version: @version]\n",
          "@version \"1.0.0\"\n@version \"1.0.1\"\ndef project, do: [version: @version]\n",
          "def project, do: [version: \"1.0.0\", version: \"1.0.0\"]\n",
          "@version \"1.0.0\"\ndef project, do: [version: \"1.0.0\"]\n",
          "def project, do: [version: \"1.0.0\"\n",
          "def project, do: [version: \"1.0.0\")\n"
        ] do
      write_project(root, "apps/child/mix.exs", source)
      before = snapshot(root)
      assert {:error, message} = Versions.update(root, "2.0.0")
      assert message =~ "apps/child/mix.exs"
      assert snapshot(root) == before
    end
  end

  test "does not evaluate Mix files or rewrite comments and other literals", %{root: root} do
    marker = Path.join(root, "evaluated")
    source = "File.write!(#{inspect(marker)}, \"executed\")\n" <> attribute("1.0.0")
    source = source <> "# version: \"9.9.9\"\n@description \"version: 8.8.8\"\n"
    write_project(root, "mix.exs", source)
    assert :ok = Versions.update(root, "2.0.0")

    assert File.read!(Path.join(root, "mix.exs")) ==
             String.replace(source, "@version \"1.0.0\"", "@version \"2.0.0\"")

    refute File.exists?(marker)
  end

  test "reports a missing root project", %{root: root} do
    assert {:error, message} = Versions.check(root)
    assert message =~ "mix.exs"
    assert {:error, _} = Versions.update(root, "2.0.0")
  end

  test "preserves Unicode, comments and CRLF around a version declaration", %{root: root} do
    source = "# 配置 é\r\ndef project, do: [description: \"你好 é\", version: \"1.0.0\"]\r\n"
    write_project(root, "mix.exs", source)
    assert :ok = Versions.update(root, "2.0.0")
    assert File.read!(Path.join(root, "mix.exs")) == String.replace(source, "1.0.0", "2.0.0")
  end

  test "shell CLI locates the repository from its script path and checks read-only", %{root: root} do
    for file <- ["update_version.sh", "update_version.exs", "lib/release/versions.ex"] do
      destination = Path.join([root, "scripts", file])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.expand("../#{file}", __DIR__), destination)
    end

    write_project(root, "mix.exs", literal("1.0.0"))
    write_project(root, "apps/child/mix.exs", attribute("0.1.0"))
    script = Path.join(root, "scripts/update_version.sh")
    options = [cd: System.tmp_dir!(), env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true]
    before = snapshot(root)
    assert {_, 1} = System.cmd("bash", [script, "--check"], options)
    assert snapshot(root) == before
    assert {_, 0} = System.cmd("bash", [script, "2.0.0"], options)
    assert {_, 0} = System.cmd("bash", [script, "--check", "2.0.0"], options)
    assert {:ok, "2.0.0"} = Versions.check(root)
    assert {_, 1} = System.cmd("bash", [script], options)
    assert {_, 1} = System.cmd("bash", [script, "1.0.0", "extra"], options)
  end

  defp write_project(root, path, content) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  defp literal(version) do
    "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: #{inspect(version)}]\nend\n"
  end

  defp attribute(version) do
    "defmodule Fixture.MixProject do\n  use Mix.Project\n  @version #{inspect(version)}\n  def project, do: [app: :fixture, version: @version]\n  defp deps, do: [{:other, @version, in_umbrella: true}]\nend\n"
  end

  defp snapshot(root) do
    root
    |> Path.join("**/mix.exs")
    |> Path.wildcard()
    |> Map.new(&{&1, File.read!(&1)})
  end
end
