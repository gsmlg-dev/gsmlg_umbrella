defmodule GSMLG.ProxyRules.OperationalTest do
  use ExUnit.Case, async: true

  @application_root Path.expand("../../..", __DIR__)
  @umbrella_root Path.expand("../..", @application_root)
  @runtime_directories ["/etc/gsmlg/proxy-rules", "/var/lib/gsmlg/proxy-rules"]

  test "all Docker runtime images create and persist the proxy-rules directories" do
    for dockerfile <- ~w(Dockerfile Dockerfile.alpine Dockerfile.lite) do
      contents = File.read!(Path.join(@umbrella_root, dockerfile))
      runtime_stage = contents |> String.split(~r/^FROM /m) |> List.last()

      mkdir_command =
        runtime_stage
        |> String.split("\n")
        |> Enum.find(fn line ->
          String.starts_with?(String.trim_leading(line), ["mkdir -p", "&& mkdir -p"])
        end)

      volume_command = runtime_stage |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^VOLUME /))

      assert is_binary(mkdir_command), "#{dockerfile} runtime stage must run mkdir -p"

      for directory <- @runtime_directories do
        assert mkdir_command =~ directory,
               "#{dockerfile} runtime mkdir command must create #{directory}"
      end

      assert volume_command =~ "/var/lib/gsmlg/proxy-rules",
             "#{dockerfile} must declare the proxy-rules state directory as a volume"
    end
  end

  test "tarball and systemd deployment protect proxy-rules configuration and state" do
    deploy = File.read!(Path.join(@umbrella_root, "docs/deploy.md"))

    account_setup = :binary.match(deploy, "sudo groupadd --system gsmlg")
    user_setup = :binary.match(deploy, "sudo useradd --system --gid gsmlg")
    directory_setup = :binary.match(deploy, "sudo install -d -o root -g gsmlg -m 0750 /etc/gsmlg")

    assert {account_offset, _length} = account_setup
    assert {user_offset, _length} = user_setup
    assert {directory_offset, _length} = directory_setup
    assert account_offset < directory_offset
    assert user_offset < directory_offset

    assert deploy =~
             "sudo install -o root -g gsmlg -m 0640 /path/to/gsmlg_umbrella.toml " <>
               "/etc/gsmlg/gsmlg_umbrella.toml"

    assert deploy =~ "StateDirectory=gsmlg/proxy-rules\nStateDirectoryMode=0750"
  end

  test "one benchmark compilation reports positive operational measurements" do
    Code.require_file(Path.join(@application_root, "bench/proxy_rules_benchmark.exs"))

    assert %{
             compile_mean_ms: compile_mean_ms,
             artifact_bytes: artifact_bytes,
             lookup_ops_per_second: lookup_ops_per_second
           } =
             apply(GSMLG.ProxyRules.Benchmark, :run, [
               [iterations: 1, lookup_iterations: 100_000]
             ])

    assert compile_mean_ms > 0
    assert artifact_bytes > 0
    assert lookup_ops_per_second > 0
  end
end
