defmodule GSMLG.AdminWeb.ProxyRulesLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.ProxyRules.{
    Compiler,
    Diagnostic,
    LocalProxyBatch,
    LocalProxyWriter,
    Snapshot,
    SourceSnapshot,
    Store
  }

  alias GSMLG.ProxyRules.Source.Local

  @compiled_at ~U[2026-07-23 01:02:03Z]
  @secret_key_base String.duplicate("p", 64)

  setup %{conn: conn} do
    prior_store_state = :sys.get_state(Store)
    prior_snapshot = Store.current()
    prior_coordinator_state = :sys.get_state(GSMLG.ProxyRules.Coordinator)

    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
      restore_store(prior_store_state, prior_snapshot)

      :sys.replace_state(GSMLG.ProxyRules.Coordinator, fn _state ->
        prior_coordinator_state
      end)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    authenticated_conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(
        GSMLG.AdminWeb.Guardian,
        user,
        %{},
        token_type: "access"
      )
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{
      conn: authenticated_conn,
      unauthenticated_conn: Phoenix.ConnTest.build_conn() |> with_secret_key_base()
    }
  end

  test "redirects unauthenticated requests to sign in", %{unauthenticated_conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/proxy-rules")
  end

  test "renders the explicit not-ready dashboard state", %{conn: conn} do
    replace_current(nil, :not_ready, %{kind: :store, reason: :snapshot_not_found})
    {:ok, view, html} = live(conn, ~p"/proxy-rules")

    assert html =~ "Proxy Rules"
    assert has_element?(view, "#proxy-rules-status", "Not ready")
    assert has_element?(view, "#proxy-rules-generation", "Not available")
    assert has_element?(view, "#proxy-rules-compiled-at", "Not available")
    assert has_element?(view, "#proxy-rules-proxy-count", "Not available")
    assert has_element?(view, "#proxy-rules-direct-count", "Not available")
    assert has_element?(view, "#proxy-rules-source-remote-gfwlist", "Not available")
    assert has_element?(view, "#proxy-rules-source-local-proxy-list", "Not available")
    refute has_element?(view, "#proxy-rules-source-local-direct-list")
    refute render(view) =~ "Local direct"
    assert has_element?(view, "#proxy-rules-artifacts-empty", "No artifacts have been published.")
    refute has_element?(view, "#proxy-rules-artifacts a")
  end

  test "renders all operational states with truthful badges and refresh availability", %{
    conn: conn
  } do
    snapshot = fixture_snapshot()

    for {readiness, label, disabled?} <- [
          {:not_ready, "Not ready", false},
          {:refreshing, "Refreshing", true},
          {:ready, "Ready", false},
          {:stale, "Stale", false}
        ] do
      replace_current(
        if(readiness == :not_ready, do: nil, else: %{snapshot | readiness: readiness}),
        readiness,
        nil
      )

      {:ok, view, _html} = live(conn, ~p"/proxy-rules")
      assert has_element?(view, "#proxy-rules-status", label)

      if disabled? do
        assert has_element?(view, "#proxy-rules-refresh[disabled][aria-disabled='true']")
      else
        assert has_element?(view, "#proxy-rules-refresh[phx-click='refresh']")
        refute has_element?(view, "#proxy-rules-refresh[disabled]")
      end
    end
  end

  test "renders summary, sources, bounded diagnostics, and six absolute artifacts", %{conn: conn} do
    snapshot = fixture_snapshot()
    replace_sources(snapshot.source_versions)
    replace_current(snapshot, :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    assert has_element?(view, "#proxy-rules-generation", "42")
    assert has_element?(view, "#proxy-rules-compiled-at", "2026-07-23 01:02:03Z")
    assert has_element?(view, "#proxy-rules-proxy-count", "2")
    assert has_element?(view, "#proxy-rules-direct-count", "1")

    for {id, label, source} <- [
          {"remote-gfwlist", "Remote GFWList", :gfwlist},
          {"local-proxy-list", "Local proxy list", :local_proxy}
        ] do
      version = snapshot.source_versions[source]
      assert has_element?(view, "#proxy-rules-source-#{id}", label)
      assert has_element?(view, "#proxy-rules-source-#{id} [title='#{version}']")
    end

    refute has_element?(view, "#proxy-rules-source-local-direct-list")
    refute render(view) =~ "Local direct"

    assert has_element?(view, "#proxy-rules-diagnostic-invalid", "1")
    assert has_element?(view, "#proxy-rules-diagnostic-unsupported", "2")
    assert has_element?(view, "#proxy-rules-diagnostic-duplicate", "3")
    assert has_element?(view, "#proxy-rules-diagnostic-collapsed", "4")
    assert has_element?(view, "#proxy-rules-diagnostic-conflict", "5")
    assert has_element?(view, "#proxy-rules-diagnostic-samples li", "invalid · gfwlist")
    assert has_element?(view, "#proxy-rules-diagnostic-samples li", "unsupported · local proxy")
    refute render(view) =~ "third.example"

    base_url = GSMLG.Web.Endpoint.url()

    for {list_path, list_label} <- [{"proxy-list", "Proxy"}, {"direct-list", "Direct"}],
        {format_path, format_label} <- [{"raw", "Raw"}, {"squid", "Squid"}, {"clash", "Clash"}] do
      output = artifact(snapshot, list_path, format_path)
      url = "#{base_url}/api/proxy-rules/#{list_path}/#{format_path}"

      assert has_element?(
               view,
               "#proxy-rules-artifacts a[href='#{url}'][aria-label='Download #{list_label} #{format_label}']"
             )

      assert has_element?(view, "#proxy-rules-artifacts [title='#{output.etag}']")
    end

    assert has_element?(view, "section > #proxy-rules-artifacts-heading")

    refute has_element?(
             view,
             "#proxy-rules-artifacts [role='heading'] #proxy-rules-artifacts-heading"
           )
  end

  test "renders the local proxy form and lazy source viewer without eager source content", %{
    conn: conn
  } do
    snapshot = fixture_snapshot()

    replace_source_snapshots(%{
      remote:
        source_snapshot(
          :remote,
          snapshot.source_versions.gfwlist,
          @compiled_at,
          %{
            content: "||remote-secret.example^\n||second.example^\n",
            fetched_at: @compiled_at
          }
        ),
      local_proxy:
        source_snapshot(
          :local_proxy,
          snapshot.source_versions.local_proxy,
          @compiled_at,
          %{content: "local-secret.example\n", last_success_at: @compiled_at}
        ),
      local_direct:
        source_snapshot(
          :local_direct,
          snapshot.source_versions.local_direct,
          @compiled_at,
          %{last_success_at: @compiled_at}
        )
    })

    replace_current(snapshot, :ready, nil)
    {:ok, view, html} = live(conn, ~p"/proxy-rules")

    assert has_element?(view, "#proxy-rules-add-local-proxy")
    assert has_element?(view, "form[phx-submit='add_local_proxy']")

    assert has_element?(
             view,
             "textarea[name='local_proxy[domains]'][aria-describedby='proxy-rules-local-proxy-help proxy-rules-local-proxy-errors']"
           )

    assert has_element?(
             view,
             "#proxy-rules-source-viewer[phx-hook='ProxyRulesSourceViewer'][data-page-size='200']"
           )

    assert has_element?(view, "[data-source='gfwlist'][data-loaded='false']")
    assert has_element?(view, "[data-source='local-proxy'][data-loaded='false']")
    assert has_element?(view, "#proxy-rules-viewer-gfwlist-status", "Ready")
    assert has_element?(view, "#proxy-rules-viewer-local-proxy-status", "Ready")
    assert has_element?(view, "#proxy-rules-viewer-gfwlist-metadata", "2 lines")
    assert has_element?(view, "#proxy-rules-viewer-gfwlist-metadata", "2026-07-23 01:02:03Z")

    assert has_element?(
             view,
             "label[for='proxy-rules-local-proxy-domains']",
             "One domain per line"
           )

    assert has_element?(view, "#proxy-rules-add-local-proxy-submit", "Add domains")

    assert has_element?(
             view,
             "#proxy-rules-local-proxy-help",
             "One leading . or *. prefix is accepted and removed"
           )

    assert has_element?(view, "#proxy-rules-source-viewport[phx-update='ignore']")
    refute html =~ "||remote-secret.example^"
    refute html =~ "local-secret.example"
  end

  @tag :tmp_dir
  test "adds canonical local domains, reports duplicates, clears input, and invalidates viewer",
       %{
         conn: conn,
         tmp_dir: dir
       } do
    proxy_path = install_local_mutation_state(dir)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    html =
      view
      |> form("#proxy-rules-add-local-proxy", %{
        "local_proxy" => %{"domains" => "*.Baidu.com\nbaidu.com\n"}
      })
      |> render_submit()

    assert html =~ "Added 1 domain"
    assert html =~ "ignored 1 duplicate"
    assert has_element?(view, "textarea[name='local_proxy[domains]']", "")
    assert File.read!(proxy_path) == "existing.example\nbaidu.com\n"

    assert_push_event(view, "proxy-rules:source-changed", %{source: "local-proxy"})

    html =
      view
      |> form("#proxy-rules-add-local-proxy", %{
        "local_proxy" => %{"domains" => "BAIDU.com\n"}
      })
      |> render_submit()

    assert html =~ "No domains were added"
    assert html =~ "ignored 1 duplicate"
    assert has_element?(view, "textarea[name='local_proxy[domains]']", "")
    assert File.read!(proxy_path) == "existing.example\nbaidu.com\n"
    assert_push_event(view, "proxy-rules:source-changed", %{source: "local-proxy"})
  end

  @tag :tmp_dir
  test "retains the exact invalid submission and renders bounded line errors", %{
    conn: conn,
    tmp_dir: dir
  } do
    _proxy_path = install_local_mutation_state(dir)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")
    domains = "Good.example  \nhttps://bad.example\n"

    view
    |> form("#proxy-rules-add-local-proxy", %{"local_proxy" => %{"domains" => domains}})
    |> render_submit()

    assert view |> element("textarea[name='local_proxy[domains]']") |> render() =~ domains
    assert has_element?(view, "#proxy-rules-local-proxy-errors[role='alert']")

    assert has_element?(
             view,
             "#proxy-rules-local-proxy-errors li",
             "Line 2: URLs are not allowed"
           )
  end

  @tag :tmp_dir
  test "shows bounded operational errors and retains the submitted domains", %{
    conn: conn,
    tmp_dir: dir
  } do
    _proxy_path = install_local_mutation_state(dir)
    set_local_writer(fn _path, _content -> {:error, :permission_denied} end)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    view
    |> form("#proxy-rules-add-local-proxy", %{
      "local_proxy" => %{"domains" => "private.example\n"}
    })
    |> render_submit()

    assert render(view) =~ "Local proxy source could not be written: permission denied."

    assert view |> element("textarea[name='local_proxy[domains]']") |> render() =~
             "private.example\n"

    set_local_writer(&LocalProxyWriter.write/2)

    too_many =
      1..(LocalProxyBatch.max_distinct_domains() + 1)
      |> Enum.map_join("\n", &"domain#{&1}.example")

    view
    |> form("#proxy-rules-add-local-proxy", %{"local_proxy" => %{"domains" => too_many}})
    |> render_submit()

    assert render(view) =~ "Submit at most 10,000 distinct domains at a time."
  end

  @tag :tmp_dir
  test "warns after committed additions with unknown durability or failed reconciliation", %{
    conn: conn,
    tmp_dir: dir
  } do
    proxy_path = install_local_mutation_state(dir)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    set_local_writer(fn path, content ->
      File.write!(path, content)
      {:ok, :durability_unknown}
    end)

    html =
      view
      |> form("#proxy-rules-add-local-proxy", %{
        "local_proxy" => %{"domains" => "uncertain.example\n"}
      })
      |> render_submit()

    assert html =~ "Added 1 domain"
    assert html =~ "durable storage confirmation is unknown"
    assert File.read!(proxy_path) =~ "uncertain.example\n"

    set_local_writer(fn path, content ->
      File.write!(path, content)
      File.rm!(path)
      File.ln_s!(Path.basename(path), path)
      :ok
    end)

    html =
      view
      |> form("#proxy-rules-add-local-proxy", %{
        "local_proxy" => %{"domains" => "stale.example\n"}
      })
      |> render_submit()

    assert html =~ "Added 1 domain"
    assert html =~ "viewer may be stale because reconciliation failed"
  end

  @tag :tmp_dir
  test "never creates atoms from submitted domain text", %{conn: conn, tmp_dir: dir} do
    _proxy_path = install_local_mutation_state(dir)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")
    unique = "never-an-atom-#{System.unique_integer([:positive])}.example"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end

    view
    |> form("#proxy-rules-add-local-proxy", %{"local_proxy" => %{"domains" => unique}})
    |> render_submit()

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
  end

  @tag :tmp_dir
  test "rejects malformed add payloads without losing form state or crashing", %{
    conn: conn,
    tmp_dir: dir
  } do
    proxy_path = install_local_mutation_state(dir)
    replace_current(fixture_snapshot(), :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")
    retained_domains = "https://keep-this-exact.example\n"

    view
    |> form("#proxy-rules-add-local-proxy", %{
      "local_proxy" => %{"domains" => retained_domains}
    })
    |> render_submit()

    assert has_element?(view, "#proxy-rules-local-proxy-errors li")

    for payload <- [
          %{},
          %{"local_proxy" => %{}},
          %{"local_proxy" => %{"domains" => ["malformed-secret"]}}
        ] do
      html = render_submit(view, "add_local_proxy", payload)

      assert html =~ "The domain submission is invalid. Enter one domain per line."
      refute html =~ "malformed-secret"
      refute has_element?(view, "#proxy-rules-local-proxy-errors li")

      assert view |> element("textarea[name='local_proxy[domains]']") |> render() =~
               retained_domains

      assert Process.alive?(view.pid)
    end

    html =
      render_submit(view, "add_local_proxy", %{
        "local_proxy" => %{"domains" => "after-malformed.example\n"}
      })

    assert html =~ "Added 1 domain"
    assert File.read!(proxy_path) =~ "after-malformed.example\n"
  end

  test "distinguishes never-successful and previously successful stale local sources", %{
    conn: conn
  } do
    failed_at = ~U[2026-07-23 01:12:13Z]
    successful_at = @compiled_at

    replace_source_snapshots(%{
      remote: nil,
      local_proxy:
        source_snapshot(
          :local_proxy,
          String.duplicate("b", 64),
          failed_at,
          %{last_success_at: nil},
          :stale
        ),
      local_direct:
        source_snapshot(
          :local_direct,
          String.duplicate("c", 64),
          failed_at,
          %{last_success_at: successful_at},
          :stale
        )
    })

    replace_current(fixture_snapshot(), :stale, %{kind: :local_proxy, reason: :invalid_utf8})
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    assert has_element?(
             view,
             "#proxy-rules-source-local-proxy-list",
             "Last success Not available"
           )

    refute has_element?(view, "#proxy-rules-source-local-direct-list")
    refute render(view) =~ "Local direct"

    assert has_element?(view, "#proxy-rules-viewer-gfwlist-status", "Missing")
    assert has_element?(view, "#proxy-rules-viewer-local-proxy-status", "Stale")
  end

  test "accepted refresh immediately disables duplicate clicks", %{conn: conn} do
    snapshot = fixture_snapshot()
    replace_current(snapshot, :ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    assert render_click(view, "refresh") =~ "Refreshing"
    assert has_element?(view, "#proxy-rules-refresh[disabled][aria-disabled='true']")
    refute has_element?(view, "#proxy-rules-refresh[phx-click]")
  end

  test "rejected refresh keeps artifacts and flashes a concise error", %{conn: conn} do
    snapshot = fixture_snapshot()
    replace_current(snapshot, :stale, %{kind: :remote, reason: :timeout})
    prior_coordinator_state = :sys.get_state(GSMLG.ProxyRules.Coordinator)

    :sys.replace_state(GSMLG.ProxyRules.Coordinator, fn state ->
      %{state | recovery_blocked: true}
    end)

    on_exit(fn ->
      :sys.replace_state(GSMLG.ProxyRules.Coordinator, fn _state -> prior_coordinator_state end)
    end)

    {:ok, view, _html} = live(conn, ~p"/proxy-rules")
    html = render_click(view, "refresh")

    assert html =~ "Refresh is not available"
    assert has_element?(view, "#proxy-rules-artifacts a")
    assert has_element?(view, "#proxy-rules-status", "Stale")
  end

  test "reloads facade metadata after a proxy-rule PubSub event", %{conn: conn} do
    replace_current(nil, :not_ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")
    assert has_element?(view, "#proxy-rules-status", "Not ready")

    replace_current(fixture_snapshot(), :ready, nil)

    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      GSMLG.AdminWeb.ProxyRulesTelemetryBridge.topic(),
      {:proxy_rules_status_changed, %{generation: 42}, %{readiness: :ready}}
    )

    assert render(view) =~ "Ready"
    assert has_element?(view, "#proxy-rules-generation", "42")
  end

  test "marks navigation active", %{conn: conn} do
    replace_current(nil, :not_ready, nil)
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    assert has_element?(view, "details[data-menu-group='proxy_rules'][open]")
    assert has_element?(view, "a[href='/proxy-rules'][aria-current='page']", "Dashboard")
  end

  defp fixture_snapshot do
    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 42,
               compiled_at: @compiled_at,
               sample_limit: 2
             )

    diagnostics = [
      %Diagnostic{
        kind: :invalid,
        source: :gfwlist,
        location: 2,
        reason: :invalid_value,
        sample: "bad.example"
      },
      %Diagnostic{
        kind: :unsupported,
        source: :local_proxy,
        location: 3,
        reason: :wildcard,
        sample: "*.example"
      },
      %Diagnostic{
        kind: :unsupported,
        source: :local_direct,
        location: 4,
        reason: :path_specific,
        sample: "third.example/private"
      }
    ]

    statistics = %{
      snapshot.statistics
      | duplicate_count: 3,
        collapsed_count: 4,
        conflict_count: 5,
        sources: %{
          gfwlist: %{accepted: 1, invalid: 1, unsupported: 0},
          local_proxy: %{accepted: 1, invalid: 0, unsupported: 1},
          local_direct: %{accepted: 1, invalid: 0, unsupported: 1}
        }
    }

    %{
      snapshot
      | statistics: statistics,
        diagnostics: diagnostics,
        source_versions: %{
          gfwlist: String.duplicate("a", 64),
          local_proxy: String.duplicate("b", 64),
          local_direct: String.duplicate("c", 64)
        }
    }
  end

  defp artifact(snapshot, "proxy-list", format),
    do: snapshot.rendered_outputs.proxy[to_atom(format)]

  defp artifact(snapshot, "direct-list", format),
    do: snapshot.rendered_outputs.direct[to_atom(format)]

  defp to_atom("raw"), do: :raw
  defp to_atom("squid"), do: :squid
  defp to_atom("clash"), do: :clash

  defp replace_current(snapshot, readiness, operational_status) do
    :sys.replace_state(Store, fn state ->
      snapshot =
        if snapshot,
          do: %{snapshot | readiness: readiness, last_error: operational_status},
          else: nil

      if snapshot,
        do: :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot}),
        else: :ets.delete(:gsmlg_proxy_rules_store, :current)

      %{state | readiness: readiness, operational_status: operational_status}
    end)
  end

  defp replace_sources(versions) do
    replace_source_snapshots(%{
      remote:
        source_snapshot(
          :remote,
          versions.gfwlist,
          @compiled_at,
          %{
            etag: ~s("remote-etag"),
            last_modified: "Wed, 23 Jul 2026 01:02:03 GMT",
            fetched_at: @compiled_at
          }
        ),
      local_proxy:
        source_snapshot(
          :local_proxy,
          versions.local_proxy,
          @compiled_at,
          %{last_success_at: @compiled_at}
        ),
      local_direct:
        source_snapshot(
          :local_direct,
          versions.local_direct,
          @compiled_at,
          %{last_success_at: @compiled_at}
        )
    })
  end

  defp replace_source_snapshots(sources) do
    coordinator = GSMLG.ProxyRules.Coordinator
    prior_state = :sys.get_state(coordinator)

    on_exit(fn ->
      :sys.replace_state(coordinator, fn _state -> prior_state end)
    end)

    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | remote: sources.remote,
          local_proxy: sources.local_proxy,
          local_direct: sources.local_direct
      }
    end)
  end

  defp source_snapshot(kind, version, observed_at, metadata, availability \\ :ready) do
    {content, metadata} = Map.pop(metadata, :content, "")

    %SourceSnapshot{
      kind: kind,
      content: content,
      content_sha256: version,
      observed_at: observed_at,
      line_count: SourceSnapshot.count_lines(content),
      metadata: metadata,
      availability: availability
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
        source_snapshot(
          :local_proxy,
          String.duplicate("e", 64),
          @compiled_at,
          %{
            content: "existing.example\n",
            path: proxy_path,
            last_success_at: @compiled_at
          }
        )

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

  defp set_local_writer(writer) do
    :sys.replace_state(Local, fn state -> %{state | writer: writer} end)
  end

  defp restore_store(prior_state, prior_snapshot) do
    :sys.replace_state(Store, fn _state ->
      case prior_snapshot do
        {:ok, snapshot} -> :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
        {:error, :not_ready} -> :ets.delete(:gsmlg_proxy_rules_store, :current)
      end

      prior_state
    end)
  end

  defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
