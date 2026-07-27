defmodule GSMLG.ProxyRules.OperationalTest do
  use ExUnit.Case, async: true

  @application_root Path.expand("../../..", __DIR__)
  @umbrella_root Path.expand("../..", @application_root)
  @runtime_directories ["/etc/gsmlg/proxy-rules", "/var/lib/gsmlg/proxy-rules"]

  test "all Docker runtime images create the proxy-rules directories" do
    for dockerfile <- ~w(Dockerfile Dockerfile.alpine Dockerfile.lite),
        directory <- @runtime_directories do
      contents = File.read!(Path.join(@umbrella_root, dockerfile))
      runtime_stage = contents |> String.split(~r/^FROM /m) |> List.last()

      assert runtime_stage =~ directory,
             "#{dockerfile} must create #{directory} in its runtime stage"
    end
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
