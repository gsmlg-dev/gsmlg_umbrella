defmodule GSMLG.ProxyRules.Benchmark do
  @moduledoc false

  alias GSMLG.ProxyRules.Compiler

  @default_iterations 5
  @lookup_iterations 100_000
  @fixture_path Path.expand("../test/fixtures/gfwlist/official.txt", __DIR__)

  @spec run(keyword()) :: %{
          fixture_sha256: String.t(),
          accepted_rules: non_neg_integer(),
          compile_mean_ms: float(),
          artifact_bytes: pos_integer(),
          lookup_ops_per_second: pos_integer(),
          otp_release: String.t(),
          elixir_version: String.t()
        }
  def run(options \\ []) do
    iterations = positive_option!(options, :iterations, @default_iterations)
    lookup_iterations = positive_option!(options, :lookup_iterations, @lookup_iterations)

    if lookup_iterations < @lookup_iterations do
      raise ArgumentError, "lookup_iterations must be at least #{@lookup_iterations}"
    end

    fixture = File.read!(@fixture_path)
    compiled_at = DateTime.from_unix!(0)

    {compile_microseconds, snapshots} =
      Enum.map_reduce(1..iterations, 0, fn generation, elapsed ->
        {duration, {:ok, snapshot}} =
          :timer.tc(fn ->
            Compiler.compile(
              %{remote: fixture, local_proxy: "", local_direct: ""},
              generation: generation,
              compiled_at: compiled_at,
              sample_limit: 0
            )
          end)

        {snapshot, elapsed + duration}
      end)
      |> then(fn {snapshots, elapsed} -> {elapsed, snapshots} end)

    snapshot = List.last(snapshots)
    table = :ets.new(:proxy_rules_benchmark, [:set, :protected, read_concurrency: true])

    try do
      true = :ets.insert(table, {:current, snapshot})

      {lookup_microseconds, :ok} =
        :timer.tc(fn ->
          for _iteration <- 1..lookup_iterations do
            [{:current, ^snapshot}] = :ets.lookup(table, :current)
          end

          :ok
        end)

      %{
        fixture_sha256: sha256(fixture),
        accepted_rules: accepted_rules(snapshot),
        compile_mean_ms: compile_microseconds / iterations / 1_000,
        artifact_bytes: artifact_bytes(snapshot),
        lookup_ops_per_second: round(lookup_iterations * 1_000_000 / max(lookup_microseconds, 1)),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        elixir_version: System.version()
      }
    after
      :ets.delete(table)
    end
  end

  @spec print(keyword()) :: :ok
  def print(options \\ []) do
    result = run(options)

    for key <- [
          :fixture_sha256,
          :accepted_rules,
          :compile_mean_ms,
          :artifact_bytes,
          :lookup_ops_per_second,
          :otp_release,
          :elixir_version
        ] do
      IO.puts("#{key}=#{Map.fetch!(result, key)}")
    end

    :ok
  end

  defp positive_option!(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp accepted_rules(snapshot) do
    snapshot.statistics.sources
    |> Map.values()
    |> Enum.sum_by(& &1.accepted)
  end

  defp artifact_bytes(snapshot) do
    snapshot.rendered_outputs
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.sum_by(& &1.content_length)
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end

unless Process.whereis(ExUnit.Server) do
  iterations =
    case System.argv() do
      [] -> 5
      [value] -> String.to_integer(value)
      _arguments -> raise ArgumentError, "usage: mix run proxy_rules_benchmark.exs [iterations]"
    end

  GSMLG.ProxyRules.Benchmark.print(iterations: iterations)
end
