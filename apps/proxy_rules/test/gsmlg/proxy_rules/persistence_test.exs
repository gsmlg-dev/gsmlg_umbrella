defmodule GSMLG.ProxyRules.PersistenceTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Compiler, Persistence, Snapshot}

  @compiled_at ~U[2026-07-23 01:02:03Z]

  @tag :tmp_dir
  test "round-trips a versioned checksummed artifact atomically", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(4)

    assert :ok = Persistence.write_artifact(dir, snapshot)
    assert {:ok, ^snapshot} = Persistence.read_artifact(dir)
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.bak"))
  end

  @tag :tmp_dir
  test "reports a missing snapshot without creating state", %{tmp_dir: dir} do
    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    refute File.exists?(Path.join(dir, "artifact.snapshot"))
  end

  @tag :tmp_dir
  test "rejects corrupt and truncated snapshots without crashing", %{tmp_dir: dir} do
    path = Path.join(dir, "artifact.snapshot")

    File.write!(path, "not a term")
    assert {:error, :corrupt_snapshot} = Persistence.read_artifact(dir)

    File.write!(path, :erlang.term_to_binary(%{type: :artifact, version: 1}))
    assert {:error, :corrupt_snapshot} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rejects checksum, type, and version mismatches", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(5)
    path = Path.join(dir, "artifact.snapshot")
    payload = :erlang.term_to_binary(snapshot)
    hash = :crypto.hash(:sha256, payload)

    write_envelope(path, :artifact_snapshot, 1, <<0::256>>, payload)
    assert {:error, :checksum_mismatch} = Persistence.read_artifact(dir)

    write_envelope(path, :remote_metadata, 1, hash, payload)
    assert {:error, :incompatible_snapshot} = Persistence.read_artifact(dir)

    write_envelope(path, :artifact_snapshot, 2, hash, payload)
    assert {:error, :incompatible_snapshot} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rejects a safely decoded payload that is not a valid snapshot", %{tmp_dir: dir} do
    path = Path.join(dir, "artifact.snapshot")
    payload = :erlang.term_to_binary(%{generation: 1})
    hash = :crypto.hash(:sha256, payload)

    write_envelope(path, :artifact_snapshot, 1, hash, payload)
    assert {:error, :invalid_snapshot} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rejects untrusted executable terms and invalid snapshot invariants", %{tmp_dir: dir} do
    path = Path.join(dir, "artifact.snapshot")
    executable_payload = :erlang.term_to_binary(fn -> :unsafe end)

    write_envelope(
      path,
      :artifact_snapshot,
      1,
      :crypto.hash(:sha256, executable_payload),
      executable_payload
    )

    assert {:error, :invalid_snapshot} = Persistence.read_artifact(dir)

    snapshot = fixture_snapshot(7)
    raw = %{snapshot.rendered_outputs.proxy.raw | content_length: 999}
    invalid_snapshot = put_in(snapshot.rendered_outputs.proxy.raw, raw)
    payload = :erlang.term_to_binary(invalid_snapshot)

    write_envelope(path, :artifact_snapshot, 1, :crypto.hash(:sha256, payload), payload)
    assert {:error, :invalid_snapshot} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rejects compressed ETF and files over the configured read bound", %{tmp_dir: dir} do
    path = Path.join(dir, "artifact.snapshot")
    File.write!(path, :erlang.term_to_binary(%{payload: "compressed"}, [:compressed]))
    assert {:error, :corrupt_snapshot} = Persistence.read_artifact(dir)

    compressed_payload = :erlang.term_to_binary(fixture_snapshot(7), [:compressed])

    write_envelope(
      path,
      :artifact_snapshot,
      1,
      :crypto.hash(:sha256, compressed_payload),
      compressed_payload
    )

    assert {:error, :corrupt_snapshot} = Persistence.read_artifact(dir)

    File.write!(path, :binary.copy(<<0>>, 65))

    assert {:error, :invalid_snapshot} =
             Persistence.read_artifact(dir, max_envelope_bytes: 64)
  end

  @tag :tmp_dir
  test "rejects extra struct keys and non-publishable readiness", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(8)

    assert_rejected_snapshot(dir, Map.put(snapshot, :extra, true))

    output = snapshot.rendered_outputs.proxy.raw |> Map.put(:extra, true)
    assert_rejected_snapshot(dir, put_in(snapshot.rendered_outputs.proxy.raw, output))

    diagnostic =
      %GSMLG.ProxyRules.Diagnostic{
        kind: :invalid,
        source: :gfwlist,
        location: 1,
        reason: :invalid_label
      }
      |> Map.put(:extra, true)

    assert_rejected_snapshot(dir, %{snapshot | diagnostics: [diagnostic]})
    assert_rejected_snapshot(dir, %{snapshot | readiness: :refreshing})
    assert_rejected_snapshot(dir, %{snapshot | readiness: :not_ready})

    assert {:error, :invalid_snapshot} =
             Persistence.write_artifact(dir, %{snapshot | readiness: :refreshing})

    assert {:error, :invalid_snapshot} =
             Persistence.write_artifact(dir, %{snapshot | readiness: :not_ready})
  end

  @tag :tmp_dir
  test "rejects same-size required-key substitutions without raising", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(18)

    substituted_snapshot = substitute_key(snapshot, :generation)
    refute Persistence.valid_snapshot?(substituted_snapshot)
    assert_rejected_snapshot(dir, substituted_snapshot)

    substituted_output = substitute_key(snapshot.rendered_outputs.proxy.raw, :body)
    snapshot_with_bad_output = put_in(snapshot.rendered_outputs.proxy.raw, substituted_output)
    refute Persistence.valid_snapshot?(snapshot_with_bad_output)
    assert_rejected_snapshot(dir, snapshot_with_bad_output)

    diagnostic = %GSMLG.ProxyRules.Diagnostic{
      kind: :invalid,
      source: :gfwlist,
      location: 1,
      reason: :invalid_label
    }

    substituted_diagnostic = substitute_key(diagnostic, :location)
    snapshot_with_bad_diagnostic = %{snapshot | diagnostics: [substituted_diagnostic]}
    refute Persistence.valid_snapshot?(snapshot_with_bad_diagnostic)
    assert_rejected_snapshot(dir, snapshot_with_bad_diagnostic)
  end

  @tag :tmp_dir
  test "bounds aggregate output and diagnostic retention", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(9)
    oversized_body = :binary.copy("x", Persistence.max_output_bytes() + 1)
    oversized_output = GSMLG.ProxyRules.Output.new(oversized_body, @compiled_at)
    oversized_snapshot = put_in(snapshot.rendered_outputs.proxy.raw, oversized_output)
    assert {:error, :invalid_snapshot} = Persistence.write_artifact(dir, oversized_snapshot)

    diagnostic = %GSMLG.ProxyRules.Diagnostic{
      kind: :invalid,
      source: :gfwlist,
      location: 1,
      reason: :invalid_label,
      sample: :binary.copy("x", 513)
    }

    assert {:error, :invalid_snapshot} =
             Persistence.write_artifact(dir, %{snapshot | diagnostics: [diagnostic]})

    bounded = %{diagnostic | sample: "x"}

    assert {:error, :invalid_snapshot} =
             Persistence.write_artifact(dir, %{
               snapshot
               | diagnostics: List.duplicate(bounded, Persistence.max_diagnostic_count() + 1)
             })
  end

  @tag :tmp_dir
  test "restores the prior artifact after post-rename directory sync failure", %{tmp_dir: dir} do
    first = fixture_snapshot(10)
    second = fixture_snapshot(11)
    assert :ok = Persistence.write_artifact(dir, first)

    assert {:error, :persistence_failed} =
             Persistence.write_artifact(dir, second, sync_directory: fail_sync_on_call(2, dir))

    assert {:ok, ^first} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, "artifact.snapshot"))
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.bak"))
  end

  @tag :tmp_dir
  test "removes a new artifact when post-rename directory sync fails", %{tmp_dir: dir} do
    assert {:error, :persistence_failed} =
             Persistence.write_artifact(dir, fixture_snapshot(12),
               sync_directory: fail_sync_on_call(1, dir)
             )

    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.bak"))
  end

  @tag :tmp_dir
  test "normalizes raising, throwing, and unexpected sync callbacks", %{tmp_dir: dir} do
    callbacks = [
      fn ^dir -> raise "sync failed" end,
      fn ^dir -> throw(:sync_failed) end,
      fn ^dir -> :unexpected end
    ]

    Enum.each(callbacks, fn callback ->
      assert {:error, :persistence_failed} =
               Persistence.write_artifact(dir, fixture_snapshot(13), sync_directory: callback)

      assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    end)
  end

  @tag :tmp_dir
  test "cleans the explicit temporary file when the atomic rename fails", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "artifact.snapshot"))

    assert {:error, :persistence_failed} =
             Persistence.write_artifact(dir, fixture_snapshot(6))

    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
  end

  defp fixture_snapshot(generation) do
    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(
               %{remote: Base.encode64("||example.com^\n"), local_proxy: "", local_direct: ""},
               generation: generation,
               compiled_at: @compiled_at,
               sample_limit: 1
             )

    snapshot
  end

  defp write_envelope(path, type, version, hash, payload) do
    File.write!(
      path,
      :erlang.term_to_binary(%{
        type: type,
        version: version,
        sha256: hash,
        payload: payload
      })
    )
  end

  defp assert_rejected_snapshot(dir, snapshot) do
    path = Path.join(dir, "artifact.snapshot")
    payload = :erlang.term_to_binary(snapshot)
    write_envelope(path, :artifact_snapshot, 1, :crypto.hash(:sha256, payload), payload)
    assert {:error, :invalid_snapshot} = Persistence.read_artifact(dir)
  end

  defp substitute_key(map, key) do
    map
    |> Map.delete(key)
    |> Map.put(:substituted_key, true)
  end

  defp fail_sync_on_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn ^expected_dir ->
      :ok = :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      if call == failing_call, do: {:error, :eio}, else: :ok
    end
  end
end
