defmodule GSMLG.ProxyRules.Source.LocalTestWatcher do
  def start_link(options) do
    test_process = Keyword.get(options, :test_process)
    pid = spawn_link(fn -> loop(nil, test_process) end)
    if test_process, do: send(test_process, {:watcher_started, pid, options})
    {:ok, pid}
  end

  def subscribe(pid) do
    send(pid, {:subscriber, self()})
    :ok
  end

  defp loop(subscriber, test_process) do
    receive do
      {:subscriber, new_subscriber} ->
        if test_process, do: send(test_process, {:watcher_subscribed, self()})
        loop(new_subscriber, test_process)

      {:event, path, events} ->
        if subscriber, do: send(subscriber, {:file_event, self(), {path, events}})
        loop(subscriber, test_process)

      {:crash, reason} ->
        exit(reason)
    end
  end
end

defmodule GSMLG.ProxyRules.Source.LocalTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{Configuration, SourceSnapshot}
  alias GSMLG.ProxyRules.Source.Local

  @now ~U[2026-07-23 02:03:04Z]

  @tag :tmp_dir
  test "initial missing files are usable empty missing snapshots and creation is accepted", %{
    tmp_dir: dir
  } do
    server = start_local(dir)

    assert %{
             proxy: %SourceSnapshot{content: "", availability: :missing},
             direct: %SourceSnapshot{content: "", availability: :missing}
           } = Local.snapshots(server)

    proxy = Path.join(dir, "proxy.txt")
    File.write!(proxy, "example.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{
                      kind: :local_proxy,
                      content: "example.com\n",
                      availability: :ready,
                      metadata: %{path: ^proxy},
                      observed_at: @now,
                      content_sha256: hash
                    }}

    assert hash =~ ~r/^[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "normalizes line endings and trailing horizontal whitespace but preserves comments", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "proxy.txt"), "# keep me  \r\nexample.com\t\r! second\t\n\n")
    File.write!(Path.join(dir, "direct.txt"), "   \t")
    server = start_local(dir)

    assert %{
             proxy: %SourceSnapshot{
               content: "# keep me\nexample.com\n! second\n",
               availability: :ready
             },
             direct: %SourceSnapshot{content: "", availability: :ready}
           } = Local.snapshots(server)

    File.write!(Path.join(dir, "proxy.txt"), "# changed only\nexample.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{content: "# changed only\nexample.com\n"}}
  end

  @tag :tmp_dir
  test "unchanged content is quiet and stale recovery sends freshness only", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\n")
    server = start_local(dir)
    assert %{proxy: %SourceSnapshot{content: "example.com\n"}} = Local.snapshots(server)
    flush_messages()

    assert :ok = Local.reconcile(server)
    refute_receive {:proxy_rules_source, _, _}, 30
    refute_receive {:proxy_rules_source_fresh, _, _}, 30

    File.rm!(path)
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :not_found}

    assert %{proxy: %SourceSnapshot{content: "example.com\n", availability: :stale}} =
             Local.snapshots(server)

    File.write!(path, "example.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source_fresh, :local_proxy,
                    %{path: ^path, observed_at: @now, availability: :ready}}

    refute_receive {:proxy_rules_source, :local_proxy, _}, 30
  end

  @tag :tmp_dir
  test "invalid and non UTF-8 replacements retain prior content and mark stale", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\n")
    server = start_local(dir)
    assert %{proxy: %SourceSnapshot{content: "example.com\n"}} = Local.snapshots(server)
    flush_messages()

    File.write!(path, "not a domain\n")
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :invalid_replacement}

    assert %{proxy: %SourceSnapshot{content: "example.com\n", availability: :stale}} =
             Local.snapshots(server)

    File.write!(path, <<255>>)
    assert :ok = Local.reconcile(server)

    assert %{proxy: %SourceSnapshot{content: "example.com\n", availability: :stale}} =
             Local.snapshots(server)

    File.write!(path, "example.com\n")
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_fresh, :local_proxy, _}
    File.write!(path, <<255>>)
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :invalid_utf8}
  end

  @tag :tmp_dir
  test "empty and comment-only files are valid sources", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "proxy.txt"), " \t\r\n\r\n")
    File.write!(Path.join(dir, "direct.txt"), "# comment  \r\n! another\t")
    server = start_local(dir)

    assert %{
             proxy: %SourceSnapshot{content: "", availability: :ready},
             direct: %SourceSnapshot{content: "# comment\n! another\n", availability: :ready}
           } = Local.snapshots(server)
  end

  @tag :tmp_dir
  test "a partially invalid replacement is accepted when at least one rule is valid", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\nnot a domain\n")
    server = start_local(dir)

    assert %{proxy: %SourceSnapshot{content: "example.com\nnot a domain\n", availability: :ready}} =
             Local.snapshots(server)
  end

  @tag :tmp_dir
  test "in-place edit, atomic rename, and symlink entry replacement reconcile", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "one.example\n")
    server = start_local(dir, file_system: FileSystem)
    assert %{proxy: %SourceSnapshot{content: "one.example\n"}} = Local.snapshots(server)
    flush_messages()

    File.write!(path, "two.example\n")
    assert_eventually_snapshot(server, :proxy, "two.example\n")

    replacement = Path.join(dir, "replacement")
    File.write!(replacement, "three.example\n")
    File.rename!(replacement, path)
    assert_eventually_snapshot(server, :proxy, "three.example\n")

    File.rm!(path)
    target = Path.join(dir, "target")
    File.write!(target, "four.example\n")
    File.ln_s!(target, path)
    assert_eventually_snapshot(server, :proxy, "four.example\n")
  end

  @tag :tmp_dir
  test "watches unique containing directories and relevant events debounce with stale tokens ignored",
       %{tmp_dir: dir} do
    {scheduler, cancel_timer} = scheduler(self())

    server =
      start_local(dir,
        file_system: GSMLG.ProxyRules.Source.LocalTestWatcher,
        file_system_options: [test_process: self()],
        scheduler: scheduler,
        cancel_timer: cancel_timer
      )

    assert_receive {:watcher_started, watcher, options}
    assert Keyword.fetch!(options, :dirs) == [dir]
    assert_receive {:watcher_subscribed, ^watcher}
    flush_messages()

    path = Path.join(dir, "proxy.txt")
    send(server, {:file_event, watcher, {path, [:modified]}})
    assert_receive {:scheduled, debounce1, :debounced_reconcile, 10}
    send(server, {:file_event, watcher, {path, [:renamed]}})
    assert_receive {:cancelled, ^debounce1}
    assert_receive {:scheduled, debounce2, :debounced_reconcile, 10}

    File.write!(path, "example.com\n")
    send(server, {:debounced_reconcile, debounce1})
    refute_receive {:proxy_rules_source, :local_proxy, _}, 30
    send(server, {:debounced_reconcile, debounce2})

    assert_receive {:proxy_rules_source, :local_proxy, %SourceSnapshot{content: "example.com\n"}},
                   1_000
  end

  @tag :tmp_dir
  test "irrelevant events are ignored and periodic reconciliation always reschedules", %{
    tmp_dir: dir
  } do
    {scheduler, cancel_timer} = scheduler(self())
    server = start_local(dir, scheduler: scheduler, cancel_timer: cancel_timer)
    assert_receive {:scheduled, periodic, :periodic_reconcile, 100}
    flush_messages()

    send(server, {:file_event, :unknown, {Path.join(dir, "other.txt"), [:modified]}})
    refute_receive {:scheduled, _, :debounced_reconcile, _}, 30

    File.write!(Path.join(dir, "direct.txt"), "direct.example\n")
    send(server, {:periodic_reconcile, periodic})

    assert_receive {:proxy_rules_source, :local_direct,
                    %SourceSnapshot{content: "direct.example\n"}},
                   1_000

    assert_receive {:scheduled, next_periodic, :periodic_reconcile, 100}
    refute next_periodic == periodic
  end

  @tag :tmp_dir
  test "linked watcher failure terminates Local", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)

    {:ok, server} =
      Local.start_link(
        local_options(dir,
          file_system: GSMLG.ProxyRules.Source.LocalTestWatcher,
          file_system_options: [test_process: self()]
        )
      )

    assert_receive {:watcher_started, watcher, _}
    monitor = Process.monitor(server)
    send(watcher, {:crash, :watcher_broke})

    assert_receive {:DOWN, ^monitor, :process, ^server, {:watcher_failed, :unexpected_exit}},
                   1_000
  after
    Process.flag(:trap_exit, false)
  end

  @tag :tmp_dir
  test "rejects invalid finite options", %{tmp_dir: dir} do
    assert {:error, {:invalid_option, :config}} = Local.start_link(notify: self(), config: %{})

    assert {:error, {:invalid_option, :notify}} =
             Local.start_link(config: configuration(dir), notify: :nope)

    assert {:error, {:invalid_option, :file_system}} =
             Local.start_link(config: configuration(dir), notify: self(), file_system: String)
  end

  defp start_local(dir, extra \\ []) do
    defaults = [file_system: GSMLG.ProxyRules.Source.LocalTestWatcher]
    start_supervised!({Local, local_options(dir, Keyword.merge(defaults, extra))})
  end

  defp local_options(dir, extra) do
    Keyword.merge([config: configuration(dir), notify: self(), now: fn -> @now end], extra)
  end

  defp configuration(dir) do
    struct!(Configuration,
      source_url: "https://example.test/gfwlist.txt",
      remote_refresh_interval: 1_000,
      remote_connect_timeout: 11,
      remote_receive_timeout: 12,
      remote_max_body_size: 256,
      retry_min_interval: 10,
      retry_max_interval: 80,
      retry_jitter: false,
      local_proxy_list_path: Path.join(dir, "proxy.txt"),
      local_direct_list_path: Path.join(dir, "direct.txt"),
      local_watch_debounce: 10,
      local_reconciliation_interval: 100,
      state_directory: dir,
      cache_control: "public, max-age=60",
      unsupported_rule_sample_limit: 2
    )
  end

  defp scheduler(test_process) do
    scheduler = fn _server, message, delay ->
      token = elem(message, 1)
      send(test_process, {:scheduled, token, elem(message, 0), delay})
      token
    end

    cancel_timer = fn reference ->
      send(test_process, {:cancelled, reference})
      false
    end

    {scheduler, cancel_timer}
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp assert_eventually_snapshot(server, slot, content) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_assert_eventually_snapshot(server, slot, content, deadline)
  end

  defp do_assert_eventually_snapshot(server, slot, content, deadline) do
    case Map.fetch!(Local.snapshots(server), slot) do
      %SourceSnapshot{content: ^content, availability: :ready} ->
        :ok

      _snapshot ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> do_assert_eventually_snapshot(server, slot, content, deadline)
          end
        else
          flunk("snapshot #{slot} did not reach expected content #{inspect(content)}")
        end
    end
  end
end
