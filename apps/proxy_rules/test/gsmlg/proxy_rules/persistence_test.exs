defmodule GSMLG.ProxyRules.PersistenceTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Compiler, Diagnostic, Persistence, Snapshot, SourceSnapshot}

  @compiled_at ~U[2026-07-23 01:02:03Z]
  @marker ".artifact.snapshot.transaction"
  @backup ".artifact.snapshot.backup"

  @tag :tmp_dir
  test "round-trips the original remote body through a strict typed envelope", %{tmp_dir: dir} do
    body = Base.encode64("||example.com^\n")
    snapshot = remote_snapshot("||example.com^\n")

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    assert File.read!(Path.join(dir, "remote.body")) == body
    assert {:ok, ^snapshot} = Persistence.read_remote(dir)
    assert {:ok, ^snapshot, ^body} = Persistence.read_remote_pair(dir)

    assert {:error, :invalid_snapshot} =
             Persistence.write_remote(dir, Base.encode64("different.example\n"), snapshot)
  end

  @tag :tmp_dir
  test "stable remote reads retry instead of mixing files across both renames", %{tmp_dir: dir} do
    old_body = Base.encode64("old.example\n")
    old = remote_snapshot("old.example\n")
    new_body = Base.encode64("new.example\n")
    new = remote_snapshot("new.example\n")
    assert :ok = Persistence.write_remote(dir, old_body, old)

    test_process = self()
    hook_calls = :counters.new(1, [])

    hook = fn :selected ->
      :counters.add(hook_calls, 1, 1)

      if :counters.get(hook_calls, 1) == 1 do
        send(test_process, {:reader_selected, self()})
        receive do: (:continue_reader -> :ok)
      end
    end

    reader = Task.async(fn -> Persistence.read_remote_pair(dir, stable_read_hook: hook) end)
    assert_receive {:reader_selected, reader_pid}, 2_000

    sync_calls = :counters.new(1, [])

    sync = fn ^dir ->
      :counters.add(sync_calls, 1, 1)

      if :counters.get(sync_calls, 1) == 2 do
        send(test_process, {:remote_pair_renamed, self()})
        receive do: (:continue_writer -> :ok)
      else
        :ok
      end
    end

    writer =
      Task.async(fn -> Persistence.write_remote(dir, new_body, new, sync_directory: sync) end)

    assert_receive {:remote_pair_renamed, writer_pid}, 2_000
    send(reader_pid, :continue_reader)
    assert {:ok, ^old, ^old_body} = Task.await(reader, 2_000)
    send(writer_pid, :continue_writer)
    assert :ok = Task.await(writer, 2_000)
    assert {:ok, ^new, ^new_body} = Persistence.read_remote_pair(dir)
  end

  @tag :tmp_dir
  test "rejects missing, oversized, corrupt, and mismatched remote pairs", %{tmp_dir: dir} do
    assert {:error, :snapshot_not_found} = Persistence.read_remote(dir)

    File.write!(Path.join(dir, "remote.body"), "%%%%")
    File.write!(Path.join(dir, "remote.metadata"), "bad")
    assert {:error, :corrupt_snapshot} = Persistence.read_remote(dir)

    body = Base.encode64("example.com\n")
    assert :ok = Persistence.write_remote(dir, body, remote_snapshot("example.com\n"))
    File.write!(Path.join(dir, "remote.body"), body <> "x")
    assert {:error, :checksum_mismatch} = Persistence.read_remote(dir)

    assert {:error, :invalid_snapshot} = Persistence.read_remote(dir, max_body_bytes: 2)
  end

  @tag :tmp_dir
  test "a failed remote pair update never becomes authoritative and recovers its prior cache", %{
    tmp_dir: dir
  } do
    old_body = Base.encode64("old.example\n")
    old = remote_snapshot("old.example\n")
    new_body = Base.encode64("new.example\n")
    new = remote_snapshot("new.example\n")
    assert :ok = Persistence.write_remote(dir, old_body, old)

    assert {:error, :persistence_failed} =
             Persistence.write_remote(dir, new_body, new,
               sync_directory: fail_sync_from_call(2, dir)
             )

    assert {:ok, ^old} = Persistence.read_remote(dir)
    assert :ok = Persistence.recover_remote(dir)
    assert {:ok, ^old} = Persistence.read_remote(dir)
  end

  @tag :tmp_dir
  test "remote restore rejects envelope, payload, validator, timestamp, and decoded hash tampering",
       %{
         tmp_dir: dir
       } do
    body = Base.encode64("example.com\n")
    snapshot = remote_snapshot("example.com\n")

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_envelope(dir, &Map.put(&1, :type, :artifact_snapshot))
    assert {:error, :incompatible_snapshot} = Persistence.read_remote(dir)

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_payload(dir, &Map.put(&1, :extra, true))
    assert {:error, :invalid_snapshot} = Persistence.read_remote(dir)

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_payload(dir, &Map.put(&1, :source_url, "file:///tmp/list"))
    assert {:error, :invalid_snapshot} = Persistence.read_remote(dir)

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_payload(dir, &Map.put(&1, :fetched_at, :not_a_timestamp))
    assert {:error, :invalid_snapshot} = Persistence.read_remote(dir)

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_payload(dir, &Map.put(&1, :etag, String.duplicate("x", 8_193)))
    assert {:error, :invalid_snapshot} = Persistence.read_remote(dir)

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    rewrite_remote_payload(dir, &Map.put(&1, :decoded_sha256, String.duplicate("0", 64)))
    assert {:error, :checksum_mismatch} = Persistence.read_remote(dir)
  end

  @tag :tmp_dir
  test "remote restore rejects invalid Base64 and UTF-8 after checksum-valid raw reads", %{
    tmp_dir: dir
  } do
    for invalid_body <- ["%%%%", Base.encode64(<<255>>)] do
      valid_body = Base.encode64("example.com\n")
      assert :ok = Persistence.write_remote(dir, valid_body, remote_snapshot("example.com\n"))
      File.write!(Path.join(dir, "remote.body"), invalid_body)

      rewrite_remote_payload(dir, fn payload ->
        %{payload | raw_size: byte_size(invalid_body), raw_sha256: sha256(invalid_body)}
      end)

      assert {:error, :invalid_snapshot} = Persistence.read_remote(dir)
    end
  end

  @tag :tmp_dir
  test "round-trips a versioned checksummed artifact atomically", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(4)

    assert :ok = Persistence.write_artifact(dir, snapshot)
    assert {:ok, ^snapshot} = Persistence.read_artifact(dir)
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    refute File.exists?(Path.join(dir, @backup))
    refute File.exists?(Path.join(dir, @marker))
  end

  @tag :tmp_dir
  test "restores bounded diagnostic atoms in a fresh BEAM instance", %{tmp_dir: dir} do
    diagnostic = %Diagnostic{
      kind: :invalid,
      source: :gfwlist,
      location: 27,
      reason: :ip_literal,
      sample: "|http://85.17.73.31/"
    }

    snapshot = %{fixture_snapshot(41) | diagnostics: [diagnostic]}
    assert :ok = Persistence.write_artifact(dir, snapshot)

    script = """
    case GSMLG.ProxyRules.Persistence.read_artifact(hd(System.argv())) do
      {:ok, %{generation: 41}} -> System.halt(0)
      result -> IO.inspect(result); System.halt(1)
    end
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-pa",
          Application.app_dir(:proxy_rules, "ebin"),
          "-e",
          script,
          "--",
          dir
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
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
  test "leaves a recoverable pending transaction after repeated post-rename sync failure", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(10)
    second = fixture_snapshot(11)
    assert :ok = Persistence.write_artifact(dir, first)

    assert {:error, :persistence_failed} =
             Persistence.write_artifact(dir, second, sync_directory: fail_sync_from_call(2, dir))

    assert File.regular?(Path.join(dir, @marker))
    assert File.regular?(Path.join(dir, @backup))
    assert {:ok, ^first} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, "artifact.snapshot"))
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    assert File.regular?(Path.join(dir, @marker))
    assert File.regular?(Path.join(dir, @backup))

    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))
  end

  @tag :tmp_dir
  test "removes a new artifact when post-rename directory sync fails", %{tmp_dir: dir} do
    assert {:error, :persistence_failed} =
             Persistence.write_artifact(dir, fixture_snapshot(12),
               sync_directory: fail_sync_from_call(1, dir)
             )

    assert File.regular?(Path.join(dir, @marker))
    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    assert :ok = Persistence.recover_artifact(dir)
    assert [] == Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp"))
    refute File.exists?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))
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
      assert :ok = Persistence.recover_artifact(dir)
    end)
  end

  @tag :tmp_dir
  test "pending and corrupt markers fail closed to the prior backup", %{tmp_dir: dir} do
    first = fixture_snapshot(20)
    second = fixture_snapshot(21)

    write_transaction(dir, :pending, true, first, second)

    assert {:ok, ^first} =
             Persistence.read_artifact(dir, sync_directory: fn ^dir -> {:error, :eio} end)

    assert File.regular?(Path.join(dir, @marker))
    assert File.regular?(Path.join(dir, @backup))

    assert {:ok, ^first} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    assert :ok = Persistence.recover_artifact(dir)

    write_transaction(dir, :pending, true, first, second)
    File.write!(Path.join(dir, @marker), "partial")
    assert {:ok, ^first} = Persistence.read_artifact(dir)
    assert :ok = Persistence.recover_artifact(dir)
  end

  @tag :tmp_dir
  test "pending first publication ignores the uncommitted target", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(22)
    File.write!(Path.join(dir, "artifact.snapshot"), artifact_bytes(snapshot))
    write_marker(dir, :pending, false)

    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    assert File.exists?(Path.join(dir, "artifact.snapshot"))
    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, "artifact.snapshot"))
  end

  @tag :tmp_dir
  test "committed leftovers select the new target and are cleaned before later writes", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(23)
    second = fixture_snapshot(24)
    third = fixture_snapshot(25)

    write_transaction(dir, :committed, true, first, second)
    assert {:ok, ^second} = Persistence.read_artifact(dir)
    assert File.exists?(Path.join(dir, @marker))
    assert File.exists?(Path.join(dir, @backup))
    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))

    assert :ok = Persistence.write_artifact(dir, third)
    assert {:ok, ^third} = Persistence.read_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))
  end

  @tag :tmp_dir
  test "committed cleanup failure leaves an authoritative marker for a later retry", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(30)
    second = fixture_snapshot(31)
    write_transaction(dir, :committed, true, first, second)

    assert :ok =
             Persistence.recover_artifact(dir,
               sync_directory: fail_sync_on_call(2, dir)
             )

    assert {:ok, ^second} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))

    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    assert {:ok, ^second} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rolled-back cleanup failure preserves the prior artifact until cleanup retries", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(32)
    second = fixture_snapshot(33)
    write_transaction(dir, :pending, true, first, second)

    assert :ok =
             Persistence.recover_artifact(dir,
               sync_directory: fail_sync_on_call(3, dir)
             )

    assert {:ok, ^first} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, @backup))

    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    assert {:ok, ^first} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "rolled-back first publication stays absent when cleanup retries", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(34)
    File.write!(Path.join(dir, "artifact.snapshot"), artifact_bytes(snapshot))
    write_marker(dir, :pending, false)

    assert :ok =
             Persistence.recover_artifact(dir,
               sync_directory: fail_sync_on_call(2, dir)
             )

    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    refute File.exists?(Path.join(dir, "artifact.snapshot"))

    assert :ok = Persistence.recover_artifact(dir)
    refute File.exists?(Path.join(dir, @marker))
    assert {:error, :snapshot_not_found} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "reader observes old generation while writer is post-rename and pre-commit", %{
    tmp_dir: dir
  } do
    old = fixture_snapshot(28)
    new = fixture_snapshot(29)
    assert :ok = Persistence.write_artifact(dir, old)

    test_process = self()
    counter = :counters.new(1, [])

    blocking_sync = fn ^dir ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 2 do
        send(test_process, {:post_rename_sync, self()})

        receive do
          :continue_sync -> :ok
        end
      else
        :ok
      end
    end

    writer =
      Task.async(fn -> Persistence.write_artifact(dir, new, sync_directory: blocking_sync) end)

    assert_receive {:post_rename_sync, writer_pid}, 2_000
    assert {:ok, ^old} = Persistence.read_artifact(dir)
    assert File.regular?(Path.join(dir, @marker))
    assert File.regular?(Path.join(dir, @backup))

    send(writer_pid, :continue_sync)
    assert :ok = Task.await(writer)
    assert {:ok, ^new} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "a concurrent writer fails safely while a pending marker is active", %{tmp_dir: dir} do
    test_process = self()
    counter = :counters.new(1, [])

    blocking_sync = fn ^dir ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        send(test_process, {:pending_sync, self()})

        receive do
          :continue_sync -> :ok
        end
      else
        :ok
      end
    end

    first_snapshot = fixture_snapshot(26)
    second_snapshot = fixture_snapshot(27)

    first =
      Task.async(fn ->
        Persistence.write_artifact(dir, first_snapshot, sync_directory: blocking_sync)
      end)

    assert_receive {:pending_sync, writer}, 2_000

    assert {:error, :persistence_failed} = Persistence.write_artifact(dir, second_snapshot)

    send(writer, :continue_sync)
    assert :ok = Task.await(first)
    assert {:ok, %Snapshot{generation: 26}} = Persistence.read_artifact(dir)
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

  defp remote_snapshot(content) do
    %SourceSnapshot{
      kind: :remote,
      content: content,
      content_sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      observed_at: @compiled_at,
      metadata: %{
        source_url: "https://example.test/list",
        etag: ~s("tag"),
        last_modified: "Sun, 06 Nov 1994 08:49:37 GMT",
        fetched_at: @compiled_at
      }
    }
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

  defp fail_sync_from_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn ^expected_dir ->
      :ok = :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      if call >= failing_call, do: {:error, :eio}, else: :ok
    end
  end

  defp fail_sync_on_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn ^expected_dir ->
      :ok = :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      if call == failing_call, do: {:error, :eio}, else: :ok
    end
  end

  defp write_transaction(dir, state, had_target, old_snapshot, new_snapshot) do
    File.write!(Path.join(dir, @backup), artifact_bytes(old_snapshot))
    File.write!(Path.join(dir, "artifact.snapshot"), artifact_bytes(new_snapshot))
    write_marker(dir, state, had_target)
  end

  defp write_marker(dir, state, had_target) do
    File.write!(
      Path.join(dir, @marker),
      :erlang.term_to_binary(%{version: 1, state: state, had_target: had_target})
    )
  end

  defp artifact_bytes(snapshot) do
    payload = :erlang.term_to_binary(snapshot)

    :erlang.term_to_binary(%{
      type: :artifact_snapshot,
      version: 1,
      sha256: :crypto.hash(:sha256, payload),
      payload: payload
    })
  end

  defp rewrite_remote_envelope(dir, update) do
    path = Path.join(dir, "remote.metadata")
    envelope = path |> File.read!() |> :erlang.binary_to_term([:safe]) |> update.()
    File.write!(path, :erlang.term_to_binary(envelope))
  end

  defp rewrite_remote_payload(dir, update) do
    rewrite_remote_envelope(dir, fn envelope ->
      payload =
        envelope.payload
        |> :erlang.binary_to_term([:safe])
        |> update.()
        |> :erlang.term_to_binary()

      %{envelope | payload: payload, sha256: :crypto.hash(:sha256, payload)}
    end)
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
