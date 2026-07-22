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
    payload = :erlang.term_to_binary(snapshot, [:compressed])
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
end
