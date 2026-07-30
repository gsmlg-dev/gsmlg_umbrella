defmodule GSMLG.ProxyRules.Source.LocalTestWatcher do
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})

  @impl true
  def init(options) do
    test_process = Keyword.get(options, :test_process)
    if test_process, do: send(test_process, {:watcher_started, self(), options})

    {:ok,
     %{
       subscriber: nil,
       test_process: test_process,
       on_subscribe: Keyword.get(options, :on_subscribe)
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    if state.on_subscribe, do: state.on_subscribe.()
    if state.test_process, do: send(state.test_process, {:watcher_subscribed, self()})
    {:reply, :ok, %{state | subscriber: subscriber}}
  end

  @impl true
  def handle_info({:event, path, events}, state) do
    if state.subscriber, do: send(state.subscriber, {:file_event, self(), {path, events}})
    {:noreply, state}
  end

  def handle_info({:crash, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule GSMLG.ProxyRules.Source.LocalTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{Configuration, SourceSnapshot, Store}
  alias GSMLG.ProxyRules.Source.Local

  @now ~U[2026-07-23 02:03:04Z]

  @tag :tmp_dir
  test "initial missing files are usable empty missing snapshots and creation is accepted", %{
    tmp_dir: dir
  } do
    server = start_local(dir)

    assert %{
             proxy: %SourceSnapshot{content: "", line_count: 0, availability: :missing},
             direct: %SourceSnapshot{content: "", line_count: 0, availability: :missing}
           } = Local.snapshots(server)

    proxy = Path.join(dir, "proxy.txt")
    revision = Store.source_revision(Store)
    File.write!(proxy, "example.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{
                      kind: :local_proxy,
                      content: "example.com\n",
                      line_count: 1,
                      availability: :ready,
                      metadata: %{path: ^proxy},
                      observed_at: @now,
                      content_sha256: hash
                    }}

    assert hash =~ ~r/^[0-9a-f]{64}$/
    assert Store.source_revision(Store) > revision
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
               line_count: 3,
               availability: :ready
             },
             direct: %SourceSnapshot{content: "", line_count: 0, availability: :ready}
           } = Local.snapshots(server)

    File.write!(Path.join(dir, "proxy.txt"), "# changed only\nexample.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{content: "# changed only\nexample.com\n"}}
  end

  @tag :tmp_dir
  test "unchanged content reports bounded timing and stale recovery sends freshness only", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\n")
    later = ~U[2026-07-23 02:13:14Z]
    {:ok, clock} = Agent.start_link(fn -> @now end)
    server = start_local(dir, now: fn -> Agent.get(clock, & &1) end)
    assert %{proxy: %SourceSnapshot{content: "example.com\n"}} = Local.snapshots(server)
    flush_messages()

    Agent.update(clock, fn _time -> later end)
    assert :ok = Local.reconcile(server)
    refute_receive {:proxy_rules_source, _, _}, 30

    assert_receive {:proxy_rules_source_fresh, :local_proxy,
                    %{
                      observed_at: ^later,
                      last_success_at: ^later,
                      availability: :ready
                    } = timing}

    assert Map.keys(timing) |> Enum.sort() ==
             Enum.sort([:availability, :last_success_at, :observed_at])

    File.rm!(path)
    revision = Store.source_revision(Store)
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :not_found,
                    %{
                      observed_at: ^later,
                      last_success_at: ^later,
                      availability: :stale
                    } = stale_timing}

    assert Map.keys(stale_timing) |> Enum.sort() ==
             Enum.sort([:availability, :last_success_at, :observed_at])

    assert Store.source_revision(Store) > revision

    assert %{
             proxy: %SourceSnapshot{
               content: "example.com\n",
               line_count: 1,
               availability: :stale
             }
           } =
             Local.snapshots(server)

    File.write!(path, "example.com\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source_fresh, :local_proxy,
                    %{observed_at: ^later, last_success_at: ^later, availability: :ready}}

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

    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :invalid_replacement,
                    _timing}

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
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :invalid_utf8, _timing}
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
    relative_path = Path.relative_to_cwd(path)
    File.write!(path, "one.example\n")

    server =
      start_local(dir,
        file_system: FileSystem,
        config_overrides: %{
          local_proxy_list_path: relative_path,
          local_direct_list_path: Path.relative_to_cwd(Path.join(dir, "direct.txt")),
          local_reconciliation_interval: 60_000
        }
      )

    assert %{proxy: %SourceSnapshot{content: "one.example\n"}} = Local.snapshots(server)
    await_real_watcher(server, dir)
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
    assert %{proxy: %SourceSnapshot{availability: :missing}} = Local.snapshots(server)
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
    assert_receive {:watcher_subscribed, ^watcher}
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
             Local.start_link(config: configuration(dir), notify: "not-a-process-name")

    assert {:error, {:invalid_option, :file_system}} =
             Local.start_link(config: configuration(dir), notify: self(), file_system: String)

    same_path = Path.join(dir, "same.txt")

    assert {:error, {:invalid_option, :local_source_paths}} =
             Local.start_link(
               config:
                 configuration(dir, %{
                   local_proxy_list_path: same_path,
                   local_direct_list_path: Path.join(dir, "./same.txt")
                 }),
               notify: self()
             )
  end

  @tag :tmp_dir
  test "initial invalid sources do not suppress the first later valid empty publication", %{
    tmp_dir: dir
  } do
    for {name, initial} <- [
          {"invalid-utf8", <<255>>},
          {"invalid-replacement", "not a domain\n"}
        ] do
      source_dir = Path.join(dir, name)
      File.mkdir_p!(source_dir)
      path = Path.join(source_dir, "proxy.txt")
      File.write!(path, initial)
      server = start_local(source_dir)
      assert %{proxy: %SourceSnapshot{availability: :stale}} = Local.snapshots(server)
      flush_messages()

      File.write!(path, "")
      assert :ok = Local.reconcile(server)

      assert_receive {:proxy_rules_source, :local_proxy,
                      %SourceSnapshot{content: "", availability: :ready}}

      assert :ok = GenServer.stop(server)
    end

    read_dir = Path.join(dir, "read-failure")
    File.mkdir_p!(read_dir)
    path = Path.join(read_dir, "proxy.txt")
    File.mkdir!(path)
    server = start_local(read_dir)
    assert %{proxy: %SourceSnapshot{availability: :stale}} = Local.snapshots(server)
    flush_messages()
    File.rmdir!(path)
    File.write!(path, "")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{content: "", availability: :ready}}

    assert :ok = GenServer.stop(server)
  end

  @tag :tmp_dir
  test "never-successful stale source has no last-success timestamp", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "proxy.txt"), <<255>>)
    server = start_local(dir)

    assert %{
             proxy: %SourceSnapshot{
               availability: :stale,
               observed_at: @now,
               metadata: %{last_success_at: nil}
             }
           } = Local.snapshots(server)
  end

  @tag :tmp_dir
  test "stale source retains the timestamp of its last valid read", %{tmp_dir: dir} do
    successful_at = ~U[2026-07-23 02:03:04Z]
    failed_at = ~U[2026-07-23 02:13:14Z]
    {:ok, clock} = Agent.start_link(fn -> successful_at end)
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\n")

    server = start_local(dir, now: fn -> Agent.get(clock, & &1) end)

    assert %{
             proxy: %SourceSnapshot{
               availability: :ready,
               observed_at: ^successful_at,
               metadata: %{last_success_at: ^successful_at}
             }
           } = Local.snapshots(server)

    Agent.update(clock, fn _time -> failed_at end)
    File.rm!(path)
    assert :ok = Local.reconcile(server)

    assert %{
             proxy: %SourceSnapshot{
               availability: :stale,
               observed_at: ^failed_at,
               metadata: %{last_success_at: ^successful_at}
             }
           } = Local.snapshots(server)
  end

  @tag :tmp_dir
  test "canonicalizes relative targets and metadata while keeping one same-parent watcher", %{
    tmp_dir: dir
  } do
    relative_dir = Path.relative_to_cwd(dir)
    proxy = Path.join(relative_dir, "proxy.txt")
    direct = Path.join(relative_dir, "direct.txt")
    File.write!(Path.expand(proxy), "example.com\n")

    server =
      start_local(dir,
        config_overrides: %{
          local_proxy_list_path: proxy,
          local_direct_list_path: direct
        },
        file_system_options: [test_process: self()]
      )

    assert_receive {:watcher_started, _watcher, options}
    assert Keyword.fetch!(options, :dirs) == [Path.expand(relative_dir)]
    assert %{proxy: %SourceSnapshot{metadata: %{path: path}}} = Local.snapshots(server)
    assert path == Path.expand(proxy)
  end

  @tag :tmp_dir
  test "watcher is subscribed before initial reconciliation", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "old.example\n")

    server =
      start_local(dir,
        file_system_options: [
          test_process: self(),
          on_subscribe: fn -> File.write!(path, "latest.example\n") end
        ]
      )

    assert_receive {:watcher_subscribed, _watcher}

    assert %{proxy: %SourceSnapshot{content: "latest.example\n", availability: :ready}} =
             Local.snapshots(server)
  end

  @tag :tmp_dir
  test "oversized and FIFO sources fail within finite bounds and later recover", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, :binary.copy("x", Local.max_source_bytes() + 1))
    server = start_local(dir)
    assert %{proxy: %SourceSnapshot{availability: :stale}} = Local.snapshots(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :body_too_large, _timing}

    File.rm!(path)
    {_, 0} = System.cmd("mkfifo", [path])
    started = System.monotonic_time(:millisecond)
    assert :ok = Local.reconcile(server)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < Local.read_timeout() * 3
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :read_failed, _timing}

    File.rm!(path)
    File.write!(path, "fifo-recovered.example\n")
    assert :ok = Local.reconcile(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{content: "fifo-recovered.example\n"}}
  end

  @tag :tmp_dir
  test "substantial valid sources are parsed outside the descriptor read deadline", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "proxy.txt")
    content = Enum.map_join(1..25_000, "", &"domain#{&1}.example.com\n")
    assert byte_size(content) > 300_000
    File.write!(path, content)

    server = start_local(dir)

    assert %{proxy: %SourceSnapshot{content: ^content, availability: :ready}} =
             Local.snapshots(server)

    assert_receive {:proxy_rules_source, :local_proxy,
                    %SourceSnapshot{content: ^content, availability: :ready}}
  end

  @tag :tmp_dir
  test "stale reason changes notify while identical repeats remain quiet", %{tmp_dir: dir} do
    path = Path.join(dir, "proxy.txt")
    File.write!(path, "example.com\n")
    server = start_local(dir)
    assert %{proxy: %SourceSnapshot{availability: :ready}} = Local.snapshots(server)
    flush_messages()

    File.rm!(path)
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :not_found, _timing}
    assert :ok = Local.reconcile(server)
    refute_receive {:proxy_rules_source_status, :local_proxy, :stale, :not_found, _timing}, 30

    File.write!(path, <<255>>)
    assert :ok = Local.reconcile(server)
    assert_receive {:proxy_rules_source_status, :local_proxy, :stale, :invalid_utf8, _timing}
  end

  @tag :tmp_dir
  test "missing target parents are watched through an ancestor and recover by events", %{
    tmp_dir: dir
  } do
    nested = Path.join([dir, "future", "rules"])
    proxy = Path.join(nested, "proxy.txt")
    direct = Path.join(nested, "direct.txt")

    server =
      start_local(dir,
        config_overrides: %{
          local_proxy_list_path: proxy,
          local_direct_list_path: direct,
          local_reconciliation_interval: 60_000
        },
        file_system: FileSystem
      )

    assert %{proxy: %SourceSnapshot{availability: :missing}} = Local.snapshots(server)
    await_real_watcher(server, dir)
    File.mkdir_p!(nested)
    File.write!(proxy, "created.example\n")
    assert_eventually_snapshot(server, :proxy, "created.example\n")
    assert Path.dirname(proxy) in :sys.get_state(server).watch_directories
  end

  @tag :tmp_dir
  test "normal stop explicitly terminates the watcher", %{tmp_dir: dir} do
    server = start_local(dir)
    watcher = :sys.get_state(server).watcher
    monitor = Process.monitor(watcher)
    assert :ok = GenServer.stop(server)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, _reason}, 1_000
  end

  defp start_local(dir, extra \\ []) do
    {config_overrides, extra} = Keyword.pop(extra, :config_overrides, %{})
    defaults = [file_system: GSMLG.ProxyRules.Source.LocalTestWatcher]

    start_supervised!(
      {Local, local_options(dir, Keyword.merge(defaults, extra), config_overrides)},
      restart: :temporary
    )
  end

  defp local_options(dir, extra, config_overrides \\ %{}) do
    Keyword.merge(
      [config: configuration(dir, config_overrides), notify: self(), now: fn -> @now end],
      extra
    )
  end

  defp configuration(dir, overrides \\ %{}) do
    configuration =
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

    struct!(Configuration, Map.merge(Map.from_struct(configuration), overrides))
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
    deadline = System.monotonic_time(:millisecond) + 5_000
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

  defp await_real_watcher(server, directory) do
    watcher = :sys.get_state(server).watcher
    assert :ok = FileSystem.subscribe(watcher)
    barrier = Path.join(directory, ".local-watcher-barrier")
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_real_watcher(watcher, barrier, deadline, 0)
    File.rm(barrier)
  end

  defp do_await_real_watcher(watcher, barrier, deadline, attempt) do
    File.write!(barrier, Integer.to_string(attempt))

    receive do
      {:file_event, ^watcher, {^barrier, _events}} ->
        :ok
    after
      20 ->
        if System.monotonic_time(:millisecond) < deadline do
          do_await_real_watcher(watcher, barrier, deadline, attempt + 1)
        else
          flunk("real file-system watcher did not become ready")
        end
    end
  end
end
