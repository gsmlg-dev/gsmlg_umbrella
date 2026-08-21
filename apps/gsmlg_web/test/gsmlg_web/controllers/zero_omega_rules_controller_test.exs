defmodule GSMLG.Web.ZeroOmegaRulesControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.ProxyRules.{Compiler, Snapshot, Store}

  @compiled_at ~U[2026-08-21 01:02:03Z]

  setup tags do
    prior = Store.current()
    snapshot = fixture_snapshot()
    replace_current(if(tags[:empty_store], do: nil, else: snapshot))

    on_exit(fn ->
      case prior do
        {:ok, prior_snapshot} -> replace_current(prior_snapshot)
        {:error, :not_ready} -> replace_current(nil)
      end
    end)

    {:ok, snapshot: snapshot}
  end

  test "serves Switchy binary output with immutable validators", %{conn: conn} do
    conn = get(conn, "/rules/zeroomega/switchy")
    body = response(conn, 200)

    assert body ==
             "[SwitchyOmega Conditions]\r\n\r\n" <>
               "!*.direct.example\r\n" <>
               "*.proxy.example\r\n" <>
               "*.remote.example\r\n"

    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert get_resp_header(conn, "etag") == [etag(body)]
    assert get_resp_header(conn, "last-modified") == ["Fri, 21 Aug 2026 01:02:03 GMT"]
    assert get_resp_header(conn, "x-proxy-rules-generation") == ["12"]
    assert get_resp_header(conn, "content-length") == [to_string(byte_size(body))]
  end

  test "renders Switchy result mode profile parameters", %{conn: conn} do
    conn =
      get(
        conn,
        "/rules/zeroomega/switchy?mode=result&match_profile=corp&default_profile=local"
      )

    body = response(conn, 200)
    assert body =~ "@with result\r\n"
    assert body =~ "*.proxy.example +corp\r\n"
    assert body =~ "!*.direct.example\r\n"
    assert String.ends_with?(body, "* +local\r\n")
  end

  test "serves a parameterized PAC document", %{conn: conn} do
    conn = get(conn, "/rules/zeroomega/pac?proxy=10.100.0.1%3A3128")
    body = response(conn, 200)

    assert body =~ "var proxy = 'PROXY 10.100.0.1:3128';\r\n"
    assert body =~ "'direct.example'"
    assert body =~ "'proxy.example'"
    assert body =~ "'remote.example'"

    assert get_resp_header(conn, "content-type") ==
             ["application/x-ns-proxy-autoconfig; charset=utf-8"]

    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert get_resp_header(conn, "etag") == [etag(body)]
  end

  test "canonical equivalent PAC parameters produce identical bodies and ETags", %{conn: conn} do
    first = get(conn, "/rules/zeroomega/pac?proxy=PROXY.Example%3A03128")
    second = get(recycle(conn), "/rules/zeroomega/pac?proxy=proxy.example%3A3128")

    assert response(first, 200) == response(second, 200)
    assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
  end

  test "returns 304 for weak comma-separated and wildcard ETags", %{conn: conn} do
    initial = get(conn, "/rules/zeroomega/switchy")
    [current_etag] = get_resp_header(initial, "etag")

    weak =
      recycle(conn)
      |> put_req_header("if-none-match", ~s("other", W/#{current_etag}))
      |> get("/rules/zeroomega/switchy")

    assert response(weak, 304) == ""
    assert get_resp_header(weak, "etag") == [current_etag]
    assert get_resp_header(weak, "cache-control") == ["no-cache"]

    wildcard =
      recycle(conn)
      |> put_req_header("if-none-match", "*")
      |> get("/rules/zeroomega/switchy")

    assert response(wildcard, 304) == ""
  end

  test "HEAD returns GET headers and no body", %{conn: conn} do
    get_conn = get(conn, "/rules/zeroomega/pac?proxy=proxy.example%3A3128")
    head_conn = head(recycle(conn), "/rules/zeroomega/pac?proxy=proxy.example%3A3128")

    assert response(head_conn, 200) == ""
    assert get_resp_header(head_conn, "content-type") == get_resp_header(get_conn, "content-type")

    assert get_resp_header(head_conn, "content-length") ==
             get_resp_header(get_conn, "content-length")

    assert get_resp_header(head_conn, "etag") == get_resp_header(get_conn, "etag")
  end

  test "rejects missing, duplicate, unknown, and injectable options without reflecting them", %{
    conn: conn
  } do
    paths = [
      "/rules/zeroomega/pac",
      "/rules/zeroomega/pac?proxy=a%3A1&proxy=b%3A2",
      "/rules/zeroomega/pac?proxy=proxy.example%3A3128&unknown=value",
      "/rules/zeroomega/pac?proxy=user%40proxy.example%3A3128",
      "/rules/zeroomega/switchy?mode=unknown",
      "/rules/zeroomega/switchy?match_profile=bad%2Bprofile",
      "/rules/zeroomega/switchy?mode=binary&mode=result"
    ]

    for path <- paths do
      response_conn = get(recycle(conn), path)
      body = response(response_conn, 400)
      assert body == "Invalid ZeroOmega options"
      refute body =~ "proxy.example"
      assert get_resp_header(response_conn, "cache-control") == ["no-store"]
    end
  end

  @tag empty_store: true
  test "returns 503 while no immutable policy is published", %{conn: conn} do
    conn = get(conn, "/rules/zeroomega/switchy")
    assert response(conn, 503) == "Service Unavailable"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  defp fixture_snapshot do
    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 12,
               compiled_at: @compiled_at,
               sample_limit: 2
             )

    snapshot
  end

  defp replace_current(nil) do
    :sys.replace_state(Store, fn state ->
      :ets.delete(:gsmlg_proxy_rules_store, :current)
      state
    end)
  end

  defp replace_current(snapshot) do
    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)
  end

  defp etag(body) do
    checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    ~s("sha256-#{checksum}")
  end
end
