ExUnit.start()
Code.require_file("../lib/release/hex_packages.ex", __DIR__)

defmodule GSMLG.Release.HexPackagesTest do
  use ExUnit.Case
  alias GSMLG.Release.HexPackages

  setup do
    root = Path.join(System.tmp_dir!(), "hex-release-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = System.get_env("HEX_API_KEY")
    System.put_env("HEX_API_KEY", "test-key")

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: System.put_env("HEX_API_KEY", previous),
        else: System.delete_env("HEX_API_KEY")
    end)

    %{root: root, output: Path.join(root, "archives")}
  end

  test "dependencies precede dependants regardless of input order" do
    packages = [
      package("socket", ["telemetry"]),
      package("telemetry", ["logger"]),
      package("logger")
    ]

    assert [%{app: "logger"}, %{app: "telemetry"}, %{app: "socket"}] =
             HexPackages.order!(packages)
  end

  test "unpublishable internal dependencies and cycles are rejected" do
    assert_raise ArgumentError, ~r/not enabled for Hex/, fn ->
      HexPackages.order!([package("telemetry", ["aws"])])
    end

    assert_raise ArgumentError, ~r/cycle/, fn ->
      HexPackages.order!([package("one", ["two"]), package("two", ["one"])])
    end
  end

  test "build records every candidate before publication", %{root: root, output: output} do
    packages = [package("one"), package("two", ["one"])]
    HexPackages.build!(packages, "1.2.3", output, runner())
    manifest = output |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

    assert %{"version" => "1.2.3", "packages" => [%{"app" => "one"}, %{"app" => "two"}]} =
             manifest

    refute_received {:publish, _}
    assert File.regular?(Path.join(output, "one-1.2.3.tar"))
    assert File.dir?(root)
  end

  test "a failed build leaves no manifest accepting a partial release", %{output: output} do
    failing = fn _command, _args, _options -> {"failed build", 1} end

    assert_raise RuntimeError, ~r/failed build/, fn ->
      HexPackages.build!([package("one")], "1.2.3", output, failing)
    end

    refute File.exists?(Path.join(output, "manifest.json"))
  end

  test "identical published candidates are skipped and dependencies publish first", %{
    output: output
  } do
    packages = [
      package("logger"),
      package("telemetry", ["logger"]),
      package("socket", ["telemetry"])
    ]

    run = runner(%{"logger" => "archive:logger"})
    HexPackages.build!(packages, "1.2.3", output, run)
    HexPackages.publish!(packages, "1.2.3", output, run)
    refute_received {:publish, "logger"}
    assert_received {:publish, "telemetry"}
    assert_received {:publish, "socket"}
  end

  test "a conflicting remote version stops every publication", %{output: output} do
    packages = [package("one"), package("two")]
    run = runner(%{"two" => "different archive"})
    HexPackages.build!(packages, "1.2.3", output, run)

    assert_raise RuntimeError, ~r/already exists.*different/, fn ->
      HexPackages.publish!(packages, "1.2.3", output, run)
    end

    refute_received {:publish, _}
  end

  test "registry errors are never treated as an unpublished package", %{output: output} do
    packages = [package("one")]
    run = runner(%{"one" => :unavailable})
    HexPackages.build!(packages, "1.2.3", output, run)

    assert_raise RuntimeError, ~r/HTTP 503/, fn ->
      HexPackages.publish!(packages, "1.2.3", output, run)
    end

    refute_received {:publish, _}
  end

  test "corrupt candidate archives stop before network access", %{output: output} do
    packages = [package("one")]
    HexPackages.build!(packages, "1.2.3", output, runner())
    File.write!(Path.join(output, "one-1.2.3.tar"), "corrupt")
    no_commands = fn _, _, _ -> flunk("should reject before running any command") end

    assert_raise RuntimeError, ~r/checksum/, fn ->
      HexPackages.publish!(packages, "1.2.3", output, no_commands)
    end
  end

  test "changed sources stop before publication", %{output: output} do
    packages = [package("one")]
    HexPackages.build!(packages, "1.2.3", output, runner())

    changed = fn _, args, _ ->
      path = Enum.at(args, Enum.find_index(args, &(&1 == "--output")) + 1)
      File.write!(path, "changed source")
      {"", 0}
    end

    assert_raise RuntimeError, ~r/source.*different/, fn ->
      HexPackages.publish!(packages, "1.2.3", output, changed)
    end

    refute_received {:publish, _}
  end

  test "publication failure prevents dependent packages from publishing", %{output: output} do
    packages = [package("one"), package("two", ["one"])]
    run = runner(%{}, "one")
    HexPackages.build!(packages, "1.2.3", output, run)

    assert_raise RuntimeError, ~r/publish failed/, fn ->
      HexPackages.publish!(packages, "1.2.3", output, run)
    end

    assert_received {:publish, "one"}
    refute_received {:publish, "two"}
  end

  test "missing authentication prevents commands", %{output: output} do
    System.delete_env("HEX_API_KEY")

    assert_raise RuntimeError, ~r/HEX_API_KEY/, fn ->
      HexPackages.publish!([], "1.2.3", output, fn _, _, _ -> flunk("unexpected command") end)
    end
  end

  test "manual packaging and publication are suspended before discovery or external commands", %{
    output: output
  } do
    script = Path.expand("../hex_packages.exs", __DIR__)

    for command <- ["build", "publish"] do
      {message, status} =
        System.cmd(System.find_executable("elixir"), [script, command, "1.2.3", output],
          stderr_to_stdout: true
        )

      assert status == 1
      assert message =~ "Hex packaging and publication for apps/ are suspended"
      refute File.exists?(output)
    end
  end

  defp package(app, deps \\ []) do
    %{app: app, name: app, version: "1.2.3", path: "/fixture/#{app}", deps: deps}
  end

  defp runner(published \\ %{}, failure \\ nil) do
    state = make_ref()
    Process.put(state, published)

    fn
      "mix", ["hex.build", "--output", path], options ->
        app = options[:cd] |> Path.basename()
        File.write!(path, "archive:#{app}")
        {"", 0}

      "mix", ["hex.publish", "package", "--yes"], options ->
        app = options[:cd] |> Path.basename()
        send(self(), {:publish, app})
        Process.put(state, Map.put(Process.get(state), app, "archive:#{app}"))
        if app == failure, do: {"publish failed", 1}, else: {"", 0}

      "curl", args, _options ->
        output = Enum.at(args, Enum.find_index(args, &(&1 == "--output")) + 1)
        app = args |> List.last() |> Path.basename() |> String.replace_suffix("-1.2.3.tar", "")

        case Process.get(state)[app] do
          nil ->
            {"404", 0}

          :unavailable ->
            {"503", 0}

          bytes ->
            File.write!(output, bytes)
            {"200", 0}
        end
    end
  end
end
