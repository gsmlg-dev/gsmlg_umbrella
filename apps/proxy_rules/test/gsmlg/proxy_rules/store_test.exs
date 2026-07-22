defmodule GSMLG.ProxyRules.StoreTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{Compiler, Persistence, Snapshot, Store}

  @compiled_at ~U[2026-07-23 01:02:03Z]

  setup %{tmp_dir: dir} do
    supervisor = GSMLG.ProxyRules.Supervisor
    :ok = Supervisor.terminate_child(supervisor, Store)

    {:ok, store} = Store.start_link(state_directory: dir)
    Process.unlink(store)

    on_exit(fn ->
      if current_store = Process.whereis(Store), do: GenServer.stop(current_store)
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Store)
    end)

    :ok
  end

  @tag :tmp_dir
  test "is protected and safe to read before publication" do
    assert :protected == :ets.info(:gsmlg_proxy_rules_store, :protection)
    assert true == :ets.info(:gsmlg_proxy_rules_store, :read_concurrency)
    assert [] == :ets.lookup(:gsmlg_proxy_rules_store, :current)
    assert {:error, :not_ready} == Store.current()
  end

  @tag :tmp_dir
  test "metadata reports operational readiness without fabricating artifact fields" do
    assert {:ok,
            %{
              readiness: :not_ready,
              operational_status: %{reason: :snapshot_not_found}
            } = metadata} = Store.metadata()

    refute Map.has_key?(metadata, :generation)
    refute Map.has_key?(metadata, :compiled_at)
    refute Map.has_key?(metadata, :rendered_outputs)
  end

  @tag :tmp_dir
  test "updates operational readiness before any artifact exists" do
    assert :ok = Store.update_status(:refreshing, %{kind: :remote, reason: :timeout})

    assert {:ok,
            %{
              readiness: :refreshing,
              operational_status: %{kind: :remote, reason: :timeout}
            } = metadata} = Store.metadata()

    refute Map.has_key?(metadata, :generation)
    assert {:error, :not_ready} = Store.current()
  end

  @tag :tmp_dir
  test "publishes and updates status as one complete ETS record", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(9)

    assert :ok = Store.publish(snapshot)
    assert {:ok, %Snapshot{generation: 9, readiness: :ready}} = Store.current()
    assert {:ok, ^snapshot} = Persistence.read_artifact(dir)

    assert :ok = Store.update_status(:stale, %{kind: :remote, reason: :timeout})

    assert {:ok,
            %Snapshot{
              generation: 9,
              readiness: :stale,
              last_error: %{kind: :remote, reason: :timeout}
            } = updated} = Store.current()

    assert updated.rendered_outputs == snapshot.rendered_outputs
    assert updated.generation == snapshot.generation
  end

  @tag :tmp_dir
  test "stages durably and commits or discards only an exact token", %{tmp_dir: dir} do
    first = fixture_snapshot(90)
    second = fixture_snapshot(91)

    assert {:ok, first_token} = Store.stage(Store, first)
    assert {:error, :not_ready} = Store.current()
    assert {:error, :invalid_stage} = Store.commit(Store, {:proxy_rules_stage, 0, 90})

    assert {:error, :invalid_stage} =
             Store.stage(Store, {:proxy_rules_stage, 999, 89}, first)

    assert :ok = Store.discard(Store, first_token)
    assert {:error, :not_ready} = Store.current()

    assert {:ok, second_token} = Store.stage(Store, second)
    assert {:error, :invalid_stage} = Store.commit(Store, second_token)
    assert :ok = Store.finalize(Store, second_token)
    assert {:error, :not_ready} = Store.current()
    assert :ok = Store.commit(Store, second_token)
    assert {:ok, %Snapshot{generation: 91}} = Store.current()
    assert {:ok, %Snapshot{generation: 91}} = Persistence.read_artifact(dir)
  end

  @tag :tmp_dir
  test "failed staged finalization preserves disk and ETS across restart", %{tmp_dir: dir} do
    first = fixture_snapshot(92)
    second = fixture_snapshot(93)
    assert :ok = Store.publish(first)

    restart_store(dir,
      persistence_options: [sync_directory: fail_root_sync_from_call(2, dir)]
    )

    assert {:ok, token} = Store.stage(Store, second)
    assert {:error, :persistence_failed} = Store.finalize(Store, token)
    assert {:ok, %Snapshot{generation: 92}} = Store.current()
    assert {:ok, %Snapshot{generation: 92}} = Persistence.read_artifact(dir)

    restart_store(dir)
    assert {:ok, %Snapshot{generation: 92, readiness: :stale}} = Store.current()
  end

  @tag :tmp_dir
  test "discarding a non-authoritative stage leaves disk and ETS on the prior generation", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(94)
    second = fixture_snapshot(95)
    assert :ok = Store.publish(first)
    assert {:ok, token} = Store.stage(Store, second)
    assert :ok = Store.finalize(Store, token)
    assert {:ok, %Snapshot{generation: 94}} = Store.current()
    assert {:ok, %Snapshot{generation: 94}} = Persistence.read_artifact(dir)
    assert :ok = Store.discard(Store, token)
    assert {:ok, %Snapshot{generation: 94}} = Store.current()
    assert {:ok, %Snapshot{generation: 94}} = Persistence.read_artifact(dir)

    restart_store(dir)
    assert {:ok, %Snapshot{generation: 94, readiness: :stale}} = Store.current()
  end

  @tag :tmp_dir
  test "source revision guard rejects a finalized obsolete generation", %{tmp_dir: dir} do
    first = fixture_snapshot(97)
    obsolete = fixture_snapshot(98)
    assert :ok = Store.publish(first)
    expected_revision = Store.source_revision(Store)
    assert {:ok, token} = Store.stage(Store, obsolete)
    assert :ok = Store.finalize(Store, token)

    assert Store.advance_source_revision(Store) > expected_revision
    assert {:error, :obsolete} = Store.commit_if_current(Store, token, expected_revision)
    assert {:ok, %Snapshot{generation: 97}} = Store.current()
    assert {:ok, %Snapshot{generation: 97}} = Persistence.read_artifact(dir)
    assert :ok = Store.discard(Store, token)
  end

  @tag :tmp_dir
  test "startup prunes orphan stage directories without following stage-like symlinks", %{
    tmp_dir: dir
  } do
    orphan = Path.join(dir, ".artifact-stage-123")
    outside = Path.join(dir, "outside")
    stage_like_symlink = Path.join(dir, ".artifact-stage-456")
    File.mkdir_p!(orphan)
    File.write!(Path.join(orphan, "artifact.snapshot"), "orphan")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep"), "keep")
    File.ln_s!(outside, stage_like_symlink)

    restart_store(dir)

    refute File.exists?(orphan)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(stage_like_symlink)
    assert File.read!(Path.join(outside, "keep")) == "keep"
  end

  @tag :tmp_dir
  test "restoration emits artifact and stale status telemetry", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(96)
    assert :ok = Persistence.write_artifact(dir, snapshot)
    test_process = self()
    handler = "store-restoration-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:gsmlg, :proxy_rules, :artifact, :restoration],
          [:gsmlg, :proxy_rules, :status, :change]
        ],
        fn event, measurements, metadata, _config ->
          send(test_process, {:restoration_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    restart_store(dir)

    assert_receive {:restoration_telemetry, [:gsmlg, :proxy_rules, :artifact, :restoration],
                    %{generation: 96}, %{}}

    assert_receive {:restoration_telemetry, [:gsmlg, :proxy_rules, :status, :change],
                    %{generation: 96}, %{readiness: :stale}}
  end

  @tag :tmp_dir
  test "restores a valid artifact immediately as stale", %{tmp_dir: dir} do
    snapshot = fixture_snapshot(11)
    assert :ok = Persistence.write_artifact(dir, snapshot)

    restart_store(dir)

    assert {:ok, %Snapshot{generation: 11, readiness: :stale, last_error: nil}} = Store.current()
    assert {:ok, %{generation: 11, readiness: :stale}} = Store.metadata()
  end

  @tag :tmp_dir
  test "corrupt restoration remains available for status queries", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "artifact.snapshot"), "corrupt")

    restart_store(dir)

    assert {:error, :not_ready} = Store.current()

    assert {:ok, %{readiness: :not_ready, operational_status: %{reason: :corrupt_snapshot}}} =
             Store.metadata()
  end

  @tag :tmp_dir
  test "a persistence failure preserves the previous current artifact", %{tmp_dir: dir} do
    first = fixture_snapshot(12)
    second = fixture_snapshot(13)
    assert :ok = Store.publish(first)

    moved_dir = dir <> "-moved"
    File.rename!(dir, moved_dir)
    File.write!(dir, "blocks directory recreation")

    assert {:error, :persistence_failed} = Store.publish(second)

    assert {:ok,
            %Snapshot{
              generation: 12,
              readiness: :stale,
              last_error: %{kind: :persistence, reason: :persistence_failed}
            }} = Store.current()

    assert {:ok,
            %{
              generation: 12,
              readiness: :stale,
              operational_status: %{kind: :persistence, reason: :persistence_failed}
            }} = Store.metadata()

    File.rm!(dir)
    File.rename!(moved_dir, dir)
  end

  @tag :tmp_dir
  test "a first persistence failure remains not ready", %{tmp_dir: dir} do
    moved_dir = dir <> "-moved"
    File.rename!(dir, moved_dir)
    File.write!(dir, "blocks directory recreation")

    assert {:error, :persistence_failed} = Store.publish(fixture_snapshot(14))
    assert {:error, :not_ready} = Store.current()

    assert {:ok,
            %{
              readiness: :not_ready,
              operational_status: %{kind: :persistence, reason: :persistence_failed}
            }} = Store.metadata()

    File.rm!(dir)
    File.rename!(moved_dir, dir)
  end

  @tag :tmp_dir
  test "a directory sync failure does not replace current ETS state", %{tmp_dir: dir} do
    first = fixture_snapshot(15)
    second = fixture_snapshot(16)
    assert :ok = Persistence.write_artifact(dir, first)

    restart_store(dir,
      persistence_options: [sync_directory: fail_sync_from_call(2, dir)]
    )

    assert {:error, :persistence_failed} = Store.publish(second)

    assert {:ok,
            %Snapshot{
              generation: 15,
              readiness: :stale,
              last_error: %{kind: :persistence, reason: :persistence_failed}
            }} = Store.current()

    assert File.regular?(Path.join(dir, ".artifact.snapshot.transaction"))
    restart_store(dir)
    assert {:ok, %Snapshot{generation: 15, readiness: :stale}} = Store.current()
  end

  @tag :tmp_dir
  test "a failed first publish leaves nothing restorable", %{tmp_dir: dir} do
    restart_store(dir,
      persistence_options: [sync_directory: fail_sync_from_call(1, dir)]
    )

    assert {:error, :persistence_failed} = Store.publish(fixture_snapshot(17))
    assert {:error, :not_ready} = Store.current()
    assert File.regular?(Path.join(dir, ".artifact.snapshot.transaction"))

    restart_store(dir)
    assert {:error, :not_ready} = Store.current()
    assert {:ok, %{operational_status: %{reason: :snapshot_not_found}}} = Store.metadata()
  end

  @tag :tmp_dir
  test "a later publication recovers an interrupted transaction before retrying", %{
    tmp_dir: dir
  } do
    first = fixture_snapshot(18)
    interrupted = fixture_snapshot(19)
    retry = fixture_snapshot(20)
    assert :ok = Persistence.write_artifact(dir, first)

    restart_store(dir,
      persistence_options: [sync_directory: fail_sync_on_call(2, dir)]
    )

    assert {:error, :persistence_failed} = Store.publish(interrupted)
    assert {:ok, %Snapshot{generation: 18, readiness: :stale}} = Store.current()
    assert File.regular?(Path.join(dir, ".artifact.snapshot.transaction"))

    assert :ok = Store.publish(retry)
    assert {:ok, %Snapshot{generation: 20, readiness: :ready}} = Store.current()
    assert {:ok, ^retry} = Persistence.read_artifact(dir)

    restart_store(dir)
    assert {:ok, %Snapshot{generation: 20, readiness: :stale}} = Store.current()
  end

  @tag :tmp_dir
  test "rejects invalid publication and status inputs without crashing" do
    assert {:error, :invalid_snapshot} = Store.publish(%{})
    assert {:error, :invalid_readiness} = Store.update_status(:broken, nil)
    assert {:error, :invalid_operational_error} = Store.update_status(:stale, :timeout)
    assert Process.alive?(Process.whereis(Store))
  end

  @tag :tmp_dir
  test "serializes concurrent publications into complete generations", %{tmp_dir: dir} do
    snapshots = Enum.map(20..39, &fixture_snapshot/1)

    snapshots
    |> Task.async_stream(&Store.publish/1, max_concurrency: 8, timeout: 5_000)
    |> Enum.each(fn result -> assert {:ok, :ok} == result end)

    assert {:ok, %Snapshot{generation: generation} = current} = Store.current()
    assert generation in 20..39
    assert {:ok, ^current} = Persistence.read_artifact(dir)
  end

  defp fixture_snapshot(generation) do
    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||generation#{generation}.example^\n"),
                 local_proxy: "",
                 local_direct: ""
               },
               generation: generation,
               compiled_at: @compiled_at,
               sample_limit: 1
             )

    snapshot
  end

  defp restart_store(dir, opts \\ []) do
    old_store = Process.whereis(Store)
    GenServer.stop(old_store)
    {:ok, new_store} = Store.start_link(Keyword.put(opts, :state_directory, dir))
    Process.unlink(new_store)
  end

  defp fail_sync_from_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn ^expected_dir ->
      :ok = :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      if call >= failing_call, do: {:error, :eio}, else: :ok
    end
  end

  defp fail_root_sync_from_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn directory ->
      if directory == expected_dir do
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) >= failing_call, do: {:error, :eio}, else: :ok
      else
        :ok
      end
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
end
