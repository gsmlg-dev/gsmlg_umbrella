ExUnit.start()

defmodule GSMLG.Release.PrepareReleaseTest do
  use ExUnit.Case, async: true

  setup do
    temporary =
      Path.join(System.tmp_dir!(), "prepare-release-#{System.unique_integer([:positive])}")

    root = Path.join(temporary, "source")
    remote = Path.join(temporary, "origin.git")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(temporary) end)

    git!(root, ["init", "--initial-branch=main"])
    git!(root, ["config", "user.name", "Release Test"])
    git!(root, ["config", "user.email", "release@example.test"])
    git!(root, ["init", "--bare", remote])
    git!(root, ["remote", "add", "origin", remote])

    for file <- [
          "prepare_release.sh",
          "update_version.sh",
          "update_version.exs",
          "lib/release/versions.ex"
        ] do
      destination = Path.join([root, "scripts", file])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.expand("../#{file}", __DIR__), destination)
    end

    File.write!(Path.join(root, "mix.exs"), "def project, do: [version: \"1.0.0\"]\n")
    File.mkdir_p!(Path.join(root, "apps/child"))

    File.write!(
      Path.join(root, "apps/child/mix.exs"),
      "@version \"0.1.0\"\ndef project, do: [version: @version]\n"
    )

    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "Initial source"])
    baseline = git!(root, ["rev-parse", "HEAD"])
    git!(root, ["push", "origin", "main"])
    %{root: root, remote: remote, baseline: baseline, temporary: temporary}
  end

  test "stamps a release commit and annotated tag without updating remote main", fixture do
    output_file = Path.join(fixture.temporary, "github-output")
    assert {output, 0} = prepare(fixture, "2.3.4", [{"GITHUB_OUTPUT", output_file}])
    sha = git!(fixture.root, ["rev-parse", "HEAD"])
    refute sha == fixture.baseline
    assert git!(fixture.root, ["rev-parse", "refs/tags/v2.3.4^{commit}"]) == sha
    assert git!(fixture.root, ["cat-file", "-t", "refs/tags/v2.3.4"]) == "tag"
    assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
    assert remote_ref(fixture, "refs/tags/v2.3.4^{}") == sha
    assert File.read!(output_file) == "sha=#{sha}\n"
    assert output =~ sha

    assert git!(fixture.root, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
           |> String.split("\n") == ["apps/child/mix.exs", "mix.exs"]

    assert File.read!(Path.join(fixture.root, "mix.exs")) =~ "\"2.3.4\""
    assert File.read!(Path.join(fixture.root, "apps/child/mix.exs")) =~ "@version \"2.3.4\""
    assert git!(fixture.root, ["status", "--porcelain"]) == ""
  end

  test "retry from the original checkout reuses an identical tag tree", fixture do
    assert {_, 0} = prepare(fixture, "2.0.0")
    tag_object = git!(fixture.root, ["rev-parse", "refs/tags/v2.0.0"])
    release_sha = git!(fixture.root, ["rev-parse", "refs/tags/v2.0.0^{commit}"])
    git!(fixture.root, ["reset", "--hard", fixture.baseline])

    assert {output, 0} = prepare(fixture, "2.0.0")
    assert output =~ release_sha
    assert git!(fixture.root, ["rev-parse", "HEAD"]) == fixture.baseline
    assert git!(fixture.root, ["rev-parse", "refs/tags/v2.0.0"]) == tag_object
    assert remote_ref(fixture, "refs/tags/v2.0.0^{}") == release_sha
    assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
  end

  test "a conflicting release tag leaves tag and remote refs unchanged", fixture do
    assert {_, 0} = prepare(fixture, "2.0.0")
    tag_object = git!(fixture.root, ["rev-parse", "refs/tags/v2.0.0"])
    git!(fixture.root, ["reset", "--hard", fixture.baseline])
    File.write!(Path.join(fixture.root, "README.md"), "Different implementation source")
    git!(fixture.root, ["add", "README.md"])
    git!(fixture.root, ["commit", "-m", "Change source after release"])
    changed_source = git!(fixture.root, ["rev-parse", "HEAD"])

    assert {output, 1} = prepare(fixture, "2.0.0")
    assert output =~ "different source tree"
    assert git!(fixture.root, ["rev-parse", "HEAD"]) == changed_source
    assert git!(fixture.root, ["rev-parse", "refs/tags/v2.0.0"]) == tag_object
    assert remote_ref(fixture, "refs/tags/v2.0.0") == tag_object
    assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
  end

  test "invalid semantic versions fail before changing source, index or refs", fixture do
    for version <- ["1.2", "v1.2.3", "01.2.3", "--check"] do
      assert {_, 1} = prepare(fixture, version)
      assert git!(fixture.root, ["status", "--porcelain"]) == ""
      assert git!(fixture.root, ["rev-parse", "HEAD"]) == fixture.baseline
      assert git!(fixture.root, ["tag", "--list"]) == ""
      assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
    end
  end

  test "rejects valid SemVer that cannot form Docker release tags before source or Git writes",
       fixture do
    before_root = File.read!(Path.join(fixture.root, "mix.exs"))
    before_child = File.read!(Path.join(fixture.root, "apps/child/mix.exs"))
    before_index = File.read!(Path.join(fixture.root, ".git/index"))

    for version <- ["2.0.0+build.7", "2.0.0-" <> String.duplicate("a", 122)] do
      assert {:ok, _} = Version.parse(version)
      assert {output, 1} = prepare(fixture, version)
      assert output =~ "Docker-compatible"
      assert File.read!(Path.join(fixture.root, "mix.exs")) == before_root
      assert File.read!(Path.join(fixture.root, "apps/child/mix.exs")) == before_child
      assert File.read!(Path.join(fixture.root, ".git/index")) == before_index
      assert git!(fixture.root, ["rev-parse", "HEAD"]) == fixture.baseline
      assert git!(fixture.root, ["tag", "--list"]) == ""
      assert git!(fixture.root, ["ls-remote", "--tags", "origin"]) == ""
      assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
    end
  end

  test "ordinary prerelease versions can be prepared and pushed", fixture do
    assert {_, 0} = prepare(fixture, "2.0.0-rc.1")
    sha = git!(fixture.root, ["rev-parse", "HEAD"])
    assert remote_ref(fixture, "refs/tags/v2.0.0-rc.1^{}") == sha
    assert remote_ref(fixture, "refs/heads/main") == fixture.baseline
  end

  test "already normalized source is tagged without an empty version commit", fixture do
    assert {_, 0} =
             System.cmd("bash", [Path.join(fixture.root, "scripts/update_version.sh"), "1.0.0"],
               env: [{"ERL_FLAGS", "+S 2:2"}]
             )

    git!(fixture.root, ["add", "mix.exs", "apps/child/mix.exs"])
    git!(fixture.root, ["commit", "-m", "Normalize versions"])
    normalized = git!(fixture.root, ["rev-parse", "HEAD"])
    assert {_, 0} = prepare(fixture, "1.0.0")
    assert git!(fixture.root, ["rev-parse", "HEAD"]) == normalized
    assert remote_ref(fixture, "refs/tags/v1.0.0^{}") == normalized
  end

  test "rejects pre-existing dirty or staged edits without publishing", fixture do
    File.write!(Path.join(fixture.root, "unrelated.txt"), "keep me")
    assert {output, 1} = prepare(fixture, "2.0.0")
    assert output =~ "clean"
    git!(fixture.root, ["add", "unrelated.txt"])
    assert {_, 1} = prepare(fixture, "2.0.0")
    assert git!(fixture.root, ["diff", "--cached", "--name-only"]) == "unrelated.txt"
    assert git!(fixture.root, ["rev-parse", "HEAD"]) == fixture.baseline
    assert git!(fixture.root, ["tag", "--list"]) == ""
  end

  defp prepare(fixture, version, extra_env \\ []) do
    System.cmd("bash", [Path.join(fixture.root, "scripts/prepare_release.sh"), version],
      cd: fixture.temporary,
      env: [{"ERL_FLAGS", "+S 2:2"} | extra_env],
      stderr_to_stdout: true
    )
  end

  defp remote_ref(fixture, ref) do
    fixture.root
    |> git!(["ls-remote", "origin", ref])
    |> String.split()
    |> List.first()
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    String.trim(output)
  end
end
