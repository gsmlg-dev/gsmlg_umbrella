defmodule GSMLG.ProxyRules.TestTransport do
  @behaviour GSMLG.ProxyRules.Transport

  @impl true
  def get(url, headers, options) do
    controller = Keyword.fetch!(options, :transport_controller)
    public_options = Keyword.delete(options, :transport_controller)
    send(controller, {:transport_request, self(), url, headers, Map.new(public_options)})

    receive do
      {:transport_response, :crash} -> exit(:transport_crash)
      {:transport_response, response} -> response
    end
  end
end

defmodule GSMLG.ProxyRules.TestTransportController do
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options),
    do: {:ok, %{test_process: options[:test_process], responses: options[:responses]}}

  @impl true
  def handle_info({:transport_request, task, url, headers, options}, state) do
    [response | responses] = state.responses
    send(state.test_process, {:transport_request, task, url, headers, options})
    if response != :wait, do: send(task, {:transport_response, response})
    {:noreply, %{state | responses: responses}}
  end
end

defmodule GSMLG.ProxyRules.Source.RemoteTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{Configuration, Persistence, SourceSnapshot, Store}
  alias GSMLG.ProxyRules.Source.Remote

  @now ~U[2026-07-23 02:03:04Z]

  @tag :tmp_dir
  test "changed and identical 200 responses persist before bounded notifications", %{tmp_dir: dir} do
    body = Base.encode64("||example.com^\n")

    server =
      start_remote(dir, [
        response(200, body, [{"ETag", ~s("one")}]),
        response(200, body, [{"etag", ~s(W/"two")}])
      ])

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:proxy_rules_source, :remote,
                    %SourceSnapshot{content: "||example.com^\n", metadata: %{etag: ~s("one")}}},
                   1_000

    assert {:ok, %{metadata: %{etag: ~s("one")}}} = Persistence.read_remote(dir)

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source_fresh, :remote, %{etag: ~s(W/"two")}}, 1_000
    refute_receive {:proxy_rules_source, :remote, _}, 30
    assert {:ok, %{metadata: %{etag: ~s(W/"two")}}} = Persistence.read_remote(dir)
  end

  @tag :tmp_dir
  test "sends cached validators case-insensitively and accepts a 304", %{tmp_dir: dir} do
    body = Base.encode64("example.com\n")

    server =
      start_remote(dir, [
        response(200, body, [
          {"ETag", ~s("tag")},
          {"LAST-MODIFIED", "Sun, 06 Nov 1994 08:49:37 GMT"}
        ]),
        response(304, "", [{"Etag", ~s(W/"tag-2")}])
      ])

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:transport_request, _, _, [],
                    %{connect_timeout: 11, receive_timeout: 12, max_body_size: 256}}

    assert_receive {:proxy_rules_source, :remote, _}, 2_000

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, _, _, headers, _}
    assert {"if-none-match", ~s("tag")} in headers
    assert {"if-modified-since", "Sun, 06 Nov 1994 08:49:37 GMT"} in headers

    assert_receive {:proxy_rules_source_fresh, :remote,
                    %{etag: ~s(W/"tag-2"), last_modified: "Sun, 06 Nov 1994 08:49:37 GMT"}},
                   1_000
  end

  @tag :tmp_dir
  test "304 without a cache is a bounded failure", %{tmp_dir: dir} do
    server = start_remote(dir, [response(304, "")])
    revision = Store.source_revision(Store)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source_status, :remote, :stale, :unexpected_status}
    assert Store.source_revision(Store) > revision
    assert_receive {:scheduled, 10, _}
    refute_receive {:proxy_rules_source_fresh, _, _}, 30
  end

  @tag :tmp_dir
  test "invalid, oversized, timeout, and non-200 responses retain the previous source", %{
    tmp_dir: dir
  } do
    good = Base.encode64("example.com\n")
    bad_utf8 = Base.encode64(<<255>>)

    server =
      start_remote(dir, [
        response(200, good),
        response(200, "%%%"),
        response(200, bad_utf8),
        response(200, String.duplicate("x", 257)),
        {:error, :timeout},
        response(503, "no")
      ])

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source, :remote, first}, 1_000

    for _ <- 1..5 do
      assert {:ok, :accepted} = Remote.refresh(server)
      assert_receive {:scheduled, _, _}
    end

    assert {:ok, restored} = Persistence.read_remote(dir)
    assert restored.content_sha256 == first.content_sha256
    refute_receive {:proxy_rules_source, :remote, _}, 30
  end

  @tag :tmp_dir
  test "a valid response with zero accepted rules cannot replace the remote cache", %{
    tmp_dir: dir
  } do
    good = Base.encode64("||example.com^\n")
    zero_accepted = Base.encode64("! comments only\n/path-specific.example/path\n")

    server =
      start_remote(dir, [
        response(200, good),
        response(200, zero_accepted),
        response(200, good)
      ])

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source, :remote, original}, 1_000
    assert {:ok, original_cache, original_body} = Persistence.read_remote_pair(dir)

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:proxy_rules_source_status, :remote, :stale, :no_accepted_rules}, 1_000
    refute_receive {:proxy_rules_source, :remote, _}, 30
    refute_receive {:proxy_rules_source_fresh, :remote, _}, 30

    assert %SourceSnapshot{content_sha256: hash} = Remote.snapshot(server)
    assert hash == original.content_sha256
    assert %SourceSnapshot{availability: :stale} = Remote.snapshot(server)
    assert {:stale, :no_accepted_rules} == Remote.status(server)
    assert {:ok, ^original_cache, ^original_body} = Persistence.read_remote_pair(dir)

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source_fresh, :remote, _metadata}, 1_000
    assert %SourceSnapshot{availability: :ready} = Remote.snapshot(server)
    assert :ready == Remote.status(server)
  end

  @tag :tmp_dir
  @tag timeout: 30_000
  test "large 200 acceptance scanning does not block the Remote mailbox", %{tmp_dir: dir} do
    decoded = String.duplicate("||path.example/path\n", 300_000)
    body = Base.encode64(decoded)

    server =
      start_remote(dir, [response(200, body)],
        config_overrides: %{remote_max_body_size: byte_size(body) + 1}
      )

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, _, _, _, _}
    Process.sleep(10)

    started = System.monotonic_time(:millisecond)
    assert nil == Remote.snapshot(server)
    assert System.monotonic_time(:millisecond) - started < 100
    assert_receive {:proxy_rules_source_status, :remote, :stale, :no_accepted_rules}, 20_000
  end

  @tag :tmp_dir
  test "persistence failure and task crash retain state and schedule retry", %{tmp_dir: dir} do
    body = Base.encode64("example.com\n")
    server = start_remote(dir, [response(200, body), :crash], persistence: FailingPersistence)

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:scheduled, 10, _}
    refute_receive {:proxy_rules_source, _, _}, 30

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:scheduled, 20, _}
    assert Process.alive?(server)
  end

  @tag :tmp_dir
  test "active manual refreshes coalesce into one transport request", %{tmp_dir: dir} do
    server = start_remote(dir, [:wait])
    assert {:ok, :accepted} = Remote.refresh(server)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, task, _, _, _}
    refute_receive {:transport_request, _, _, _, _}, 30
    send(task, {:transport_response, response(200, Base.encode64("example.com\n"))})
    assert_receive {:proxy_rules_source, :remote, _}, 1_000
  end

  @tag :tmp_dir
  test "automatic initial fetch announces refreshing before completion", %{tmp_dir: dir} do
    server = start_remote(dir, [:wait], initial_fetch: true)
    assert_receive {:proxy_rules_source_status, :remote, :refreshing, nil}
    assert_receive {:transport_request, task, _, _, _}
    assert nil == Remote.snapshot(server)
    revision = Store.source_revision(Store)

    send(task, {:transport_response, response(200, Base.encode64("example.com\n"))})
    assert_receive {:proxy_rules_source, :remote, %SourceSnapshot{availability: :ready}}, 1_000
    assert Store.source_revision(Store) > revision
  end

  @tag :tmp_dir
  test "rejects a transport module that does not implement get/3", %{tmp_dir: dir} do
    assert {:error, {:invalid_option, :transport}} =
             Remote.start_link(remote_options(dir, [], transport: String))
  end

  @tag :tmp_dir
  test "defaults to the Finch transport behavior module", %{tmp_dir: dir} do
    options = remote_options(dir, [], transport: GSMLG.ProxyRules.TestTransport)
    assert {:ok, server} = Remote.start_link(Keyword.delete(options, :transport))
    assert %{transport: GSMLG.ProxyRules.Transport.Finch} = :sys.get_state(server)
    GenServer.stop(server)
  end

  test "retry delay is capped, exact without jitter, and bounded with jitter" do
    assert Remote.retry_delay(10, 80, 0, false, fn _ -> 1 end) == 10
    assert Remote.retry_delay(10, 80, 3, false, fn _ -> 1 end) == 80
    assert Remote.retry_delay(10, 80, 100_000, false, fn _ -> 1 end) == 80
    assert Remote.retry_delay(10, 80, 2, true, fn 40 -> 17 end) == 17
  end

  @tag :tmp_dir
  test "emits bounded fetch telemetry without response bodies or headers", %{tmp_dir: dir} do
    handler = "remote-test-#{System.unique_integer([:positive])}"
    test_process = self()

    events = [
      [:gsmlg, :proxy_rules, :remote, :fetch, :start],
      [:gsmlg, :proxy_rules, :remote, :fetch, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _config ->
          send(test_process, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    body = Base.encode64("example.com\n")
    server = start_remote(dir, [response(200, body, [{"etag", ~s("bounded")}])])

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:telemetry, [:gsmlg, :proxy_rules, :remote, :fetch, :start], %{},
                    %{source: :gfwlist}}

    assert_receive {:telemetry, [:gsmlg, :proxy_rules, :remote, :fetch, :stop], measurements,
                    %{source: :gfwlist, status: 200}},
                   1_000

    assert measurements.response_size == byte_size(body)
    refute Map.has_key?(measurements, :body)
  end

  @tag :tmp_dir
  test "manual refresh cancels and replaces the scheduled timer", %{tmp_dir: dir} do
    server = start_remote(dir, [response(503, ""), response(200, Base.encode64("example.com\n"))])
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, _, _, _, _}
    assert_receive {:scheduled, 10, first_ref}
    %{timer: %{token: stale_token}} = :sys.get_state(server)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:cancelled, ^first_ref}
    assert_receive {:transport_request, _, _, _, _}
    assert_receive {:proxy_rules_source, :remote, _}, 2_000
    assert_receive {:scheduled, 100, second_ref}
    refute first_ref == second_ref

    send(server, {:scheduled_refresh, stale_token})
    refute_receive {:transport_request, _, _, _, _}, 30
  end

  @tag :tmp_dir
  test "restores and announces a valid cache before an offline initial fetch", %{tmp_dir: dir} do
    content = "example.com\n"
    body = Base.encode64(content)
    snapshot = source_snapshot(content, %{etag: ~s("cached"), last_modified: nil})
    assert :ok = Persistence.write_remote(dir, body, snapshot)

    _server = start_remote(dir, [{:error, :connection_failed}], initial_fetch: true)

    assert_receive {:proxy_rules_source, :remote,
                    %SourceSnapshot{
                      content: ^content,
                      availability: :stale,
                      metadata: %{etag: ~s("cached")}
                    }},
                   1_000

    assert_receive {:scheduled, 10, _}
  end

  @tag :tmp_dir
  test "restore rejects a checksummed cache with zero accepted rules", %{tmp_dir: dir} do
    handler = "remote-restore-zero-#{System.unique_integer([:positive])}"
    test_process = self()

    :ok =
      :telemetry.attach(
        handler,
        [:gsmlg, :proxy_rules, :remote, :fetch, :exception],
        fn event, measurements, metadata, _config ->
          send(test_process, {:restore_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    content = "! comments only\n/path-specific.example/path\n"
    body = Base.encode64(content)
    snapshot = source_snapshot(content, %{etag: ~s("cached"), last_modified: nil})
    assert :ok = Persistence.write_remote(dir, body, snapshot)
    assert {:ok, cached, ^body} = Persistence.read_remote_pair(dir)

    server = start_remote(dir, [], initial_fetch: false)

    assert nil == Remote.snapshot(server)
    assert {:stale, :no_accepted_rules} == Remote.status(server)

    assert_receive {:proxy_rules_source_status, :remote, :stale, :no_accepted_rules}

    assert_receive {:restore_telemetry, [:gsmlg, :proxy_rules, :remote, :fetch, :exception], %{},
                    %{source: :gfwlist, failure_category: :no_accepted_rules}}

    refute_receive {:proxy_rules_source, :remote, _}, 50
    refute_receive {:proxy_rules_source_fresh, :remote, _}, 50
    assert {:ok, ^cached, ^body} = Persistence.read_remote_pair(dir)
  end

  @tag :tmp_dir
  test "an identical successful refresh recovers a restored stale cache", %{tmp_dir: dir} do
    content = "example.com\n"
    body = Base.encode64(content)
    snapshot = source_snapshot(content, %{etag: ~s("cached"), last_modified: nil})
    assert :ok = Persistence.write_remote(dir, body, snapshot)

    server = start_remote(dir, [response(304, "", [{"etag", ~s("cached")}])])
    assert_receive {:proxy_rules_source, :remote, %SourceSnapshot{availability: :stale}}
    assert %SourceSnapshot{availability: :stale} = Remote.snapshot(server)

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source_fresh, :remote, _}, 1_000
    assert %SourceSnapshot{availability: :ready} = Remote.snapshot(server)
  end

  @tag :tmp_dir
  test "URL migration ignores the old cache and sends no stale validators", %{tmp_dir: dir} do
    content = "example.com\n"
    body = Base.encode64(content)

    snapshot =
      content
      |> source_snapshot(%{etag: ~s("old"), last_modified: nil})
      |> put_in([Access.key!(:metadata), :source_url], "https://old.example/list")

    assert :ok = Persistence.write_remote(dir, body, snapshot)
    _server = start_remote(dir, [response(304, "")], initial_fetch: true)

    assert_receive {:transport_request, _, _, [], _}
    assert_receive {:scheduled, 10, _}
    refute_receive {:proxy_rules_source, :remote, _}, 30
    refute_receive {:proxy_rules_source_fresh, :remote, _}, 30
  end

  @tag :tmp_dir
  test "restore enforces the configured raw body bound", %{tmp_dir: dir} do
    content = String.duplicate("a", 300)
    body = Base.encode64(content)

    assert :ok =
             Persistence.write_remote(
               dir,
               body,
               source_snapshot(content, %{etag: nil, last_modified: nil})
             )

    _server =
      start_remote(dir, [], initial_fetch: false, config_overrides: %{remote_max_body_size: 64})

    refute_receive {:proxy_rules_source, :remote, _}, 50
  end

  @tag :tmp_dir
  test "restore merges the configured size bound with injected persistence options", %{
    tmp_dir: dir
  } do
    config = configuration(dir, %{remote_max_body_size: 64})

    options =
      Remote.persistence_read_options(config,
        test_process: self(),
        sentinel: :kept,
        max_body_bytes: 999
      )

    assert options[:sentinel] == :kept
    assert options[:max_body_bytes] == 64
  end

  @tag :tmp_dir
  test "repeated 304 uses the prior authoritative pair after a failed post-rename update", %{
    tmp_dir: dir
  } do
    old_content = "old.example\n"
    old_body = Base.encode64(old_content)
    server = start_remote(dir, [response(200, old_body), response(304, ""), response(304, "")])
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source, :remote, %SourceSnapshot{content: ^old_content}}, 3_000

    new_content = "new.example\n"

    assert {:error, :persistence_failed} =
             Persistence.write_remote(
               dir,
               Base.encode64(new_content),
               source_snapshot(new_content, %{etag: nil, last_modified: nil}),
               sync_directory: fail_sync_from_call(2, dir)
             )

    for _ <- 1..2 do
      assert {:ok, :accepted} = Remote.refresh(server)
      assert_receive {:proxy_rules_source_fresh, :remote, _}, 3_000
    end

    assert {:ok, %SourceSnapshot{content: ^old_content}, ^old_body} =
             Persistence.read_remote_pair(dir)
  end

  @tag :tmp_dir
  test "rejects duplicate and malformed response validators while retaining the old source", %{
    tmp_dir: dir
  } do
    body = Base.encode64("example.com\n")
    valid_date = "Sun, 06 Nov 1994 08:49:37 GMT"

    invalid_headers = [
      [{"etag", ~s("one")}, {"ETag", ~s("two")}],
      [{"etag", ""}],
      [{"etag", ~s("unterminated)}],
      [{"last-modified", "not a date"}],
      [{"last-modified", valid_date}, {"LAST-MODIFIED", valid_date}]
    ]

    responses =
      [response(200, body, [{"etag", ~s("valid")}, {"last-modified", valid_date}])] ++
        Enum.map(invalid_headers, &response(200, body, &1)) ++
        [response(304, "", [{"etag", ~s("a")}, {"ETAG", ~s("b")}])]

    server = start_remote(dir, responses)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source, :remote, original}, 1_000
    assert_receive {:scheduled, 100, _}

    for _ <- 1..6 do
      assert {:ok, :accepted} = Remote.refresh(server)
      assert_receive {:scheduled, _, _}
    end

    assert {:ok, restored} = Persistence.read_remote(dir)
    assert restored.content_sha256 == original.content_sha256
  end

  @tag :tmp_dir
  test "graceful stop terminates an active supervised transport task", %{tmp_dir: dir} do
    server = start_remote(dir, [:wait])
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, task, _, _, _}
    task_monitor = Process.monitor(task)

    assert :ok = stop_supervised(Remote)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}, 1_000
    refute_receive {:proxy_rules_source, :remote, _}, 30
  end

  defmodule FailingPersistence do
    def read_remote(_directory, _opts), do: {:error, :snapshot_not_found}
    def write_remote(_directory, _body, _snapshot, _opts), do: {:error, :persistence_failed}
  end

  defp start_remote(dir, responses, extra \\ []) do
    parent = self()

    controller =
      start_supervised!(
        {GSMLG.ProxyRules.TestTransportController, test_process: parent, responses: responses}
      )

    scheduler = fn _server, _message, delay ->
      ref = make_ref()
      send(parent, {:scheduled, delay, ref})
      ref
    end

    cancel = fn ref ->
      send(parent, {:cancelled, ref})
      true
    end

    options = [
      config: configuration(dir, Keyword.get(extra, :config_overrides, %{})),
      transport: Keyword.get(extra, :transport, GSMLG.ProxyRules.TestTransport),
      transport_options: [transport_controller: controller],
      notify: parent,
      task_supervisor: start_supervised!({Task.Supervisor, []}),
      scheduler: scheduler,
      cancel_timer: cancel,
      now: fn -> @now end,
      random: fn upper -> upper end,
      persistence: Keyword.get(extra, :persistence, Persistence),
      persistence_options: Keyword.get(extra, :persistence_options, []),
      initial_fetch: Keyword.get(extra, :initial_fetch, false)
    ]

    start_supervised!({Remote, options})
  end

  defp remote_options(dir, responses, extra) do
    parent = self()

    controller =
      start_supervised!(
        {GSMLG.ProxyRules.TestTransportController, test_process: parent, responses: responses}
      )

    [
      config: configuration(dir),
      transport: Keyword.fetch!(extra, :transport),
      transport_options: [transport_controller: controller],
      notify: parent,
      task_supervisor: start_supervised!({Task.Supervisor, []}),
      initial_fetch: false
    ]
  end

  defp configuration(dir, overrides \\ %{}) do
    configuration =
      struct!(Configuration,
        source_url: "https://example.test/gfwlist.txt",
        remote_refresh_interval: 100,
        remote_connect_timeout: 11,
        remote_receive_timeout: 12,
        remote_max_body_size: 256,
        retry_min_interval: 10,
        retry_max_interval: 80,
        retry_jitter: false,
        local_proxy_list_path: "proxy.txt",
        local_direct_list_path: "direct.txt",
        local_watch_debounce: 10,
        local_reconciliation_interval: 100,
        state_directory: dir,
        cache_control: "public, max-age=60",
        unsupported_rule_sample_limit: 2
      )

    struct!(Configuration, Map.merge(Map.from_struct(configuration), overrides))
  end

  defp response(status, body, headers \\ []),
    do: {:ok, %{status: status, headers: headers, body: body}}

  defp source_snapshot(content, validators) do
    %SourceSnapshot{
      kind: :remote,
      content: content,
      content_sha256: sha256(content),
      observed_at: @now,
      metadata:
        Map.merge(%{source_url: "https://example.test/gfwlist.txt", fetched_at: @now}, validators)
    }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp fail_sync_from_call(failing_call, expected_dir) do
    counter = :counters.new(1, [])

    fn ^expected_dir ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) >= failing_call, do: {:error, :eio}, else: :ok
    end
  end
end
