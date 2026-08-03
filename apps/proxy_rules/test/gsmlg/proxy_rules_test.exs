defmodule GSMLG.ProxyRulesTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules

  alias GSMLG.ProxyRules.{
    Compiler,
    Coordinator,
    LocalProxyBatch,
    LocalProxyWriter,
    Output,
    SourceSnapshot,
    Store
  }

  alias GSMLG.ProxyRules.Source.Local

  test "returns not-ready for every valid artifact lookup before publication" do
    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash] do
      assert {:error, :not_ready} == ProxyRules.get_artifact(list, format)
      assert {:error, :not_ready} == ProxyRules.get_artifact_response(list, format)
    end
  end

  test "returns not-found when the current snapshot lacks rendered outputs" do
    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        :ets.delete(:gsmlg_proxy_rules_store, :current)
        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, %{}})
      state
    end)

    assert {:error, :not_found} == ProxyRules.get_artifact(:proxy, :raw)
  end

  test "rejects unsupported list and renderer identifiers" do
    assert {:error, :not_found} == ProxyRules.get_artifact(:unknown, :raw)
    assert {:error, :not_found} == ProxyRules.get_artifact(:proxy, :unknown)
    assert {:error, :not_found} == ProxyRules.get_artifact_response(:unknown, :raw)
    assert {:error, :not_found} == ProxyRules.get_artifact_response(:proxy, :unknown)
  end

  test "returns a typed output from one complete current snapshot" do
    assert {:ok, snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 42,
               compiled_at: ~U[2026-07-23 00:00:00Z],
               sample_limit: 2
             )

    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        :ets.delete(:gsmlg_proxy_rules_store, :current)
        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)

    assert {:ok, %Output{body: body}} = ProxyRules.get_artifact(:proxy, :raw)
    assert body =~ "proxy.example"
  end

  test "returns generation and output from the same current snapshot" do
    prior = Store.current()

    assert {:ok, snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 43,
               compiled_at: ~U[2026-07-23 00:00:00Z],
               sample_limit: 2
             )

    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        case prior do
          {:ok, prior_snapshot} ->
            :ets.insert(:gsmlg_proxy_rules_store, {:current, prior_snapshot})

          {:error, :not_ready} ->
            :ets.delete(:gsmlg_proxy_rules_store, :current)
        end

        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)

    assert {:ok, %{generation: 43, output: %Output{body: body}}} =
             ProxyRules.get_artifact_response(:direct, :raw)

    assert body =~ "direct.example"
  end

  test "reports not-ready metadata without fabricated counts" do
    assert {:ok, %{readiness: readiness, sources: sources}} = ProxyRules.metadata()
    assert readiness in [:not_ready, :refreshing, :stale, :ready]

    assert %{
             remote_gfwlist: %{label: "Remote GFWList"},
             local_proxy: %{label: "Local proxy list"},
             local_direct: %{label: "Local direct list"}
           } = sources
  end

  test "accepts a refresh while the source service is available" do
    assert {:ok, :accepted} == ProxyRules.refresh()
  end

  @tag :tmp_dir
  test "adds local proxy domains through the facade and returns bounded validation failures", %{
    tmp_dir: dir
  } do
    proxy_path = install_local_mutation_state(dir)

    assert {:ok,
            %{
              added_count: 1,
              added_domains: ["new.example"],
              durability: :confirmed,
              reconciliation: :ok
            }} = ProxyRules.add_local_proxy_domains("new.example\n")

    assert File.read!(proxy_path) == "existing.example\nnew.example\n"

    assert {:error, {:invalid_batch, [%{line: 1, reason: :url_not_allowed}]}} =
             ProxyRules.add_local_proxy_domains("https://bad.example\n")

    assert {:error, {:invalid_batch, [%{line: 1, reason: :trailing_dot_not_allowed}]}} =
             ProxyRules.add_local_proxy_domains("bad.example.\n")

    too_many =
      1..(LocalProxyBatch.max_distinct_domains() + 1)
      |> Enum.map_join("\n", &"domain#{&1}.example")

    assert {:error, :too_many_domains} = ProxyRules.add_local_proxy_domains(too_many)
    assert {:error, {:invalid_batch, []}} = ProxyRules.add_local_proxy_domains(:not_binary)
  end

  @tag :tmp_dir
  test "forwards only bounded writer failures through the facade", %{tmp_dir: dir} do
    _proxy_path = install_local_mutation_state(dir)

    for reason <- [
          :permission_denied,
          :open_failed,
          :write_failed,
          :sync_failed,
          :close_failed,
          :mode_failed,
          :rename_failed,
          :invalid_target,
          :target_probe_failed
        ] do
      :sys.replace_state(Local, fn state ->
        %{state | writer: fn _path, _content -> {:error, reason} end}
      end)

      assert {:error, ^reason} = ProxyRules.add_local_proxy_domains("new.example\n")
    end
  end

  test "reports local mutation unavailable instead of exiting with the source service" do
    local = Process.whereis(Local)
    assert Process.unregister(Local)

    result =
      try do
        ProxyRules.add_local_proxy_domains("new.example\n")
      after
        Process.register(local, Local)
      end

    assert {:error, :not_available} = result
  end

  test "pages only remote GFWList and local proxy source snapshots through the facade" do
    prior = :sys.get_state(Coordinator)

    on_exit(fn ->
      :sys.replace_state(Coordinator, fn _state -> prior end)
    end)

    :sys.replace_state(Coordinator, fn state ->
      %{
        state
        | remote: source(:remote, "||example.com^\n"),
          local_proxy: source(:local_proxy, "proxy.example\n")
      }
    end)

    assert {:ok, %{source: :remote_gfwlist, total_lines: 1, lines: ["||example.com^"]}} =
             ProxyRules.get_source_page(:remote_gfwlist, nil, line_limit: 10)

    assert {:ok, %{source: :local_proxy, total_lines: 1, lines: ["proxy.example"]}} =
             ProxyRules.get_source_page(:local_proxy, nil, line_limit: 10)

    assert {:error, :not_found} =
             ProxyRules.get_source_page(:local_direct, nil, [])
  end

  test "reports refresh unavailable while the coordinator is unavailable" do
    assert :ok =
             Supervisor.terminate_child(
               GSMLG.ProxyRules.Supervisor,
               GSMLG.ProxyRules.Coordinator
             )

    on_exit(fn ->
      case Supervisor.restart_child(
             GSMLG.ProxyRules.Supervisor,
             GSMLG.ProxyRules.Coordinator
           ) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end)

    assert {:error, :not_available} == ProxyRules.refresh()
    assert {:error, :not_available} == ProxyRules.get_source_page(:remote_gfwlist)
    assert {:ok, metadata} = ProxyRules.metadata()
    refute Map.has_key?(metadata, :sources)
  end

  defp source(kind, content) do
    %SourceSnapshot{
      kind: kind,
      content: content,
      content_sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      observed_at: ~U[2026-07-31 00:00:00Z],
      line_count: SourceSnapshot.count_lines(content),
      metadata: %{},
      availability: :ready
    }
  end

  defp install_local_mutation_state(dir) do
    prior = :sys.get_state(Local)
    proxy_path = Path.join(dir, "proxy.txt")
    File.write!(proxy_path, "existing.example\n")

    on_exit(fn ->
      if Process.whereis(Local) do
        :sys.replace_state(Local, fn _state -> prior end)
      end
    end)

    :sys.replace_state(Local, fn state ->
      proxy_snapshot =
        :local_proxy
        |> source("existing.example\n")
        |> Map.put(:metadata, %{
          path: proxy_path,
          last_success_at: ~U[2026-07-31 00:00:00Z]
        })

      state
      |> put_in([:targets, :proxy], %{kind: :local_proxy, action: :proxy, path: proxy_path})
      |> put_in([:entries, :proxy], %{
        snapshot: proxy_snapshot,
        has_valid_snapshot: true,
        last_failure: nil
      })
      |> Map.put(:writer, &LocalProxyWriter.write/2)
    end)

    proxy_path
  end
end
