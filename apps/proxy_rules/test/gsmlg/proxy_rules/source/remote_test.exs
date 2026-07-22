defmodule GSMLG.ProxyRules.Source.RemoteTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Configuration, Persistence, SourceSnapshot}
  alias GSMLG.ProxyRules.Source.Remote

  @now ~U[2026-07-23 02:03:04Z]

  @tag :tmp_dir
  test "changed and identical 200 responses persist before bounded notifications", %{tmp_dir: dir} do
    body = Base.encode64("||example.com^\n")

    server =
      start_remote(dir, [
        response(200, body, [{"ETag", "one"}]),
        response(200, body, [{"etag", "two"}])
      ])

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:proxy_rules_source, :remote,
                    %SourceSnapshot{content: "||example.com^\n", metadata: %{etag: "one"}}},
                   1_000

    assert {:ok, %{metadata: %{etag: "one"}}} = Persistence.read_remote(dir)

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:proxy_rules_source_fresh, :remote, %{etag: "two"}}, 1_000
    refute_receive {:proxy_rules_source, :remote, _}, 30
    assert {:ok, %{metadata: %{etag: "two"}}} = Persistence.read_remote(dir)
  end

  @tag :tmp_dir
  test "sends cached validators case-insensitively and accepts a 304", %{tmp_dir: dir} do
    body = Base.encode64("example.com\n")

    server =
      start_remote(dir, [
        response(200, body, [{"ETag", "tag"}, {"LAST-MODIFIED", "date"}]),
        response(304, "", [{"Etag", "tag-2"}])
      ])

    assert {:ok, :accepted} = Remote.refresh(server)

    assert_receive {:transport_request, _, [],
                    %{connect_timeout: 11, receive_timeout: 12, max_body_size: 256}}

    assert_receive {:proxy_rules_source, :remote, _}, 1_000

    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, _, headers, _}
    assert {"if-none-match", "tag"} in headers
    assert {"if-modified-since", "date"} in headers

    assert_receive {:proxy_rules_source_fresh, :remote, %{etag: "tag-2", last_modified: "date"}},
                   1_000
  end

  @tag :tmp_dir
  test "304 without a cache is a bounded failure", %{tmp_dir: dir} do
    server = start_remote(dir, [response(304, "")])
    assert {:ok, :accepted} = Remote.refresh(server)
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
    parent = self()

    transport = fn url, headers, options ->
      send(parent, {:transport_request, url, headers, Map.new(options)})
      receive do: ({:release, response} -> response)
    end

    server = start_remote(dir, [], transport: transport)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:transport_request, _, _, _}
    refute_receive {:transport_request, _, _, _}, 30
    send_transport_task(server, {:release, response(200, Base.encode64("example.com\n"))})
    assert_receive {:proxy_rules_source, :remote, _}, 1_000
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
    server = start_remote(dir, [response(200, body, [{"etag", "secret-validator"}])])

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
    assert_receive {:transport_request, _, _, _}
    assert_receive {:scheduled, 10, first_ref}
    %{timer: %{token: stale_token}} = :sys.get_state(server)
    assert {:ok, :accepted} = Remote.refresh(server)
    assert_receive {:cancelled, ^first_ref}
    assert_receive {:transport_request, _, _, _}
    assert_receive {:proxy_rules_source, :remote, _}, 1_000
    assert_receive {:scheduled, 100, second_ref}
    refute first_ref == second_ref

    send(server, {:scheduled_refresh, stale_token})
    refute_receive {:transport_request, _, _, _}, 30
  end

  @tag :tmp_dir
  test "restores and announces a valid cache before an offline initial fetch", %{tmp_dir: dir} do
    content = "example.com\n"
    body = Base.encode64(content)
    snapshot = source_snapshot(content, %{etag: "cached", last_modified: nil})
    assert :ok = Persistence.write_remote(dir, body, snapshot)

    _server = start_remote(dir, [{:error, :connection_failed}], initial_fetch: true)

    assert_receive {:proxy_rules_source, :remote,
                    %SourceSnapshot{content: ^content, metadata: %{etag: "cached"}}},
                   1_000

    assert_receive {:scheduled, 10, _}
  end

  defmodule FailingPersistence do
    def read_remote(_directory, _opts), do: {:error, :snapshot_not_found}
    def write_remote(_directory, _body, _snapshot, _opts), do: {:error, :persistence_failed}
  end

  defp start_remote(dir, responses, extra \\ []) do
    parent = self()
    {:ok, responses} = Agent.start_link(fn -> responses end)

    transport =
      Keyword.get(extra, :transport, fn url, headers, options ->
        send(parent, {:transport_request, url, headers, Map.new(options)})

        Agent.get_and_update(responses, fn [response | rest] -> {response, rest} end)
        |> case do
          :crash -> exit(:transport_crash)
          response -> response
        end
      end)

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
      config: configuration(dir),
      transport: transport,
      notify: parent,
      task_supervisor: start_supervised!({Task.Supervisor, []}),
      scheduler: scheduler,
      cancel_timer: cancel,
      now: fn -> @now end,
      random: fn upper -> upper end,
      persistence: Keyword.get(extra, :persistence, Persistence),
      initial_fetch: Keyword.get(extra, :initial_fetch, false)
    ]

    start_supervised!({Remote, options})
  end

  defp send_transport_task(server, message) do
    %{active_task: %{pid: pid}} = :sys.get_state(server)
    send(pid, message)
  end

  defp configuration(dir) do
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
end
