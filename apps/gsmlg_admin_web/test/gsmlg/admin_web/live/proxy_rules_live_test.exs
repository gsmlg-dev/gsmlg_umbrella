defmodule GSMLG.AdminWeb.ProxyRulesLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.ProxyRules.{Compiler, Diagnostic, Snapshot, SourceSnapshot, Store}

  @compiled_at ~U[2026-07-23 01:02:03Z]
  @secret_key_base String.duplicate("p", 64)

  setup %{conn: conn} do
    prior_store_state = :sys.get_state(Store)
    prior_snapshot = Store.current()

    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
      restore_store(prior_store_state, prior_snapshot)
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
    assert has_element?(view, "#proxy-rules-source-local-direct-list", "Not available")
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
          {"local-proxy-list", "Local proxy list", :local_proxy},
          {"local-direct-list", "Local direct list", :local_direct}
        ] do
      version = snapshot.source_versions[source]
      assert has_element?(view, "#proxy-rules-source-#{id}", label)
      assert has_element?(view, "#proxy-rules-source-#{id} [title='#{version}']")
    end

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
    coordinator = GSMLG.ProxyRules.Coordinator
    prior_state = :sys.get_state(coordinator)
    observed_at = @compiled_at

    on_exit(fn ->
      :sys.replace_state(coordinator, fn _state -> prior_state end)
    end)

    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | remote:
            source_snapshot(
              :remote,
              versions.gfwlist,
              observed_at,
              %{
                etag: ~s("remote-etag"),
                last_modified: "Wed, 23 Jul 2026 01:02:03 GMT",
                fetched_at: observed_at
              }
            ),
          local_proxy: source_snapshot(:local_proxy, versions.local_proxy, observed_at, %{}),
          local_direct: source_snapshot(:local_direct, versions.local_direct, observed_at, %{})
      }
    end)
  end

  defp source_snapshot(kind, version, observed_at, metadata) do
    %SourceSnapshot{
      kind: kind,
      content: "",
      content_sha256: version,
      observed_at: observed_at,
      metadata: metadata,
      availability: :ready
    }
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
