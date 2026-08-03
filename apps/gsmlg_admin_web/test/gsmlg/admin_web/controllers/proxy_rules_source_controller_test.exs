defmodule GSMLG.AdminWeb.ProxyRulesSourceControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.ProxyRules.{Coordinator, SourceSnapshot}

  setup %{conn: conn} do
    prior_coordinator_state = :sys.get_state(Coordinator)

    on_exit(fn ->
      :sys.replace_state(Coordinator, fn _state -> prior_coordinator_state end)
    end)

    replace_sources(
      source_snapshot(:remote, "one.example\ntwo.example\nthree.example\n", %{
        source_url: "https://example.test/gfwlist.txt",
        fetched_at: ~U[2026-08-03 00:00:00Z]
      }),
      source_snapshot(:local_proxy, "local-one.example\nlocal-two.example\n", %{
        path: "/private/proxy-list.txt",
        last_success_at: ~U[2026-08-03 00:01:00Z]
      }),
      source_snapshot(:local_direct, "direct-one.example\ndirect-two.example\n", %{
        path: "/private/direct-list.txt",
        last_success_at: ~U[2026-08-03 00:02:00Z]
      })
    )

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    authenticated_conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(
        GSMLG.AdminWeb.Guardian,
        user,
        %{},
        token_type: "access"
      )
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{authenticated_conn: authenticated_conn}
  end

  test "redirects an unauthenticated browser request", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/proxy-rules/sources/gfwlist")

    assert redirected_to(conn) == "/sign_in"
  end

  test "returns a bounded decoded GFWList page", %{authenticated_conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/proxy-rules/sources/gfwlist?limit=2")

    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert %{
             "source" => "remote_gfwlist",
             "availability" => "ready",
             "lines" => ["one.example", "two.example"],
             "total_lines" => 3,
             "start_line" => 1,
             "has_more" => true,
             "next_cursor" => cursor
           } = response = json_response(conn, 200)

    assert is_binary(cursor)

    assert Map.keys(response) |> Enum.sort() ==
             ~w(availability has_more last_success_at lines next_cursor observed_at source start_line total_lines version)

    refute inspect(response) =~ "source_url"
    refute inspect(response) =~ "/private/"
  end

  test "returns local proxy pages and passes the cursor through", %{authenticated_conn: conn} do
    first =
      conn
      |> get(~p"/proxy-rules/sources/local-proxy?limit=1")
      |> json_response(200)

    assert %{
             "source" => "local_proxy",
             "lines" => ["local-one.example"],
             "start_line" => 1,
             "has_more" => true,
             "next_cursor" => cursor
           } = first

    second =
      conn
      |> get(~p"/proxy-rules/sources/local-proxy?limit=1&cursor=#{cursor}")
      |> json_response(200)

    assert %{
             "source" => "local_proxy",
             "lines" => ["local-two.example"],
             "start_line" => 2,
             "has_more" => false,
             "next_cursor" => nil
           } = second

    refute inspect(second) =~ "/private/proxy-list.txt"
  end

  test "defaults the page limit to 200", %{authenticated_conn: conn} do
    content = Enum.map_join(1..201, "\n", &"domain-#{&1}.example") <> "\n"
    replace_remote(source_snapshot(:remote, content, %{}))

    response =
      conn
      |> get(~p"/proxy-rules/sources/gfwlist")
      |> json_response(200)

    assert %{
             "lines" => lines,
             "total_lines" => 201,
             "has_more" => true,
             "next_cursor" => cursor
           } = response

    assert lines == Enum.map(1..200, &"domain-#{&1}.example")
    assert is_binary(cursor)
  end

  test "accepts limit boundaries 1 and 500", %{authenticated_conn: conn} do
    assert %{"lines" => ["one.example"], "has_more" => true} =
             conn
             |> get(~p"/proxy-rules/sources/gfwlist?limit=1")
             |> json_response(200)

    assert %{
             "lines" => ["one.example", "two.example", "three.example"],
             "has_more" => false
           } =
             conn
             |> get(~p"/proxy-rules/sources/gfwlist?limit=500")
             |> json_response(200)
  end

  test "returns local direct pages and passes an opaque cursor through", %{
    authenticated_conn: conn
  } do
    first_conn = get(conn, ~p"/proxy-rules/sources/local-direct?limit=1")

    assert get_resp_header(first_conn, "cache-control") == ["private, no-store"]

    assert %{
             "source" => "local_direct",
             "lines" => ["direct-one.example"],
             "start_line" => 1,
             "has_more" => true,
             "next_cursor" => cursor,
             "version" => version
           } = json_response(first_conn, 200)

    assert is_binary(version)
    assert is_binary(cursor)
    assert :error == Integer.parse(cursor)

    second_conn = get(conn, ~p"/proxy-rules/sources/local-direct?limit=1&cursor=#{cursor}")

    assert get_resp_header(second_conn, "cache-control") == ["private, no-store"]

    assert %{
             "source" => "local_direct",
             "lines" => ["direct-two.example"],
             "start_line" => 2,
             "has_more" => false,
             "next_cursor" => nil,
             "version" => ^version
           } = second = json_response(second_conn, 200)

    refute inspect(second) =~ "/private/direct-list.txt"
  end

  test "rejects unsupported sources with a bounded not-found error", %{
    authenticated_conn: conn
  } do
    conn = get(conn, ~p"/proxy-rules/sources/unknown")

    assert json_response(conn, 404) == %{
             "error" => %{
               "code" => "not_found",
               "message" => "Proxy rule source not found"
             }
           }
  end

  test "rejects limits outside the integer range from 1 through 500", %{
    authenticated_conn: conn
  } do
    for limit <- ["0", "501", "abc", "1.5", " 2", "2 "] do
      response =
        conn
        |> get(~p"/proxy-rules/sources/gfwlist?limit=#{limit}")
        |> json_response(422)

      assert response == %{
               "error" => %{
                 "code" => "invalid_limit",
                 "message" => "Limit must be an integer from 1 through 500"
               }
             }
    end
  end

  test "rejects nested and array limit parameters", %{authenticated_conn: conn} do
    for path <- [
          "/proxy-rules/sources/gfwlist?limit[x]=1",
          "/proxy-rules/sources/gfwlist?limit[]=1&limit[]=2"
        ] do
      error_conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(path)

      assert get_resp_header(error_conn, "cache-control") == ["private, no-store"]

      response = json_response(error_conn, 422)

      assert response == %{
               "error" => %{
                 "code" => "invalid_limit",
                 "message" => "Limit must be an integer from 1 through 500"
               }
             }
    end
  end

  test "rejects an invalid cursor", %{authenticated_conn: conn} do
    conn = get(conn, ~p"/proxy-rules/sources/gfwlist?cursor=not-a-cursor")

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "invalid_cursor",
               "message" => "Cursor is invalid"
             }
           }
  end

  test "rejects a cursor after its source changes", %{authenticated_conn: conn} do
    %{"next_cursor" => cursor} =
      conn
      |> get(~p"/proxy-rules/sources/gfwlist?limit=1")
      |> json_response(200)

    replace_remote(source_snapshot(:remote, "changed.example\n", %{}))

    changed_conn = get(conn, ~p"/proxy-rules/sources/gfwlist?cursor=#{cursor}")

    assert json_response(changed_conn, 409) == %{
             "error" => %{
               "code" => "source_changed",
               "message" => "Source changed; reload it before continuing"
             }
           }
  end

  test "returns not found when the selected source has no snapshot", %{
    authenticated_conn: conn
  } do
    replace_remote(nil)
    conn = get(conn, ~p"/proxy-rules/sources/gfwlist")

    assert json_response(conn, 404) == %{
             "error" => %{
               "code" => "not_found",
               "message" => "Proxy rule source not found"
             }
           }
  end

  test "returns unavailable while the source coordinator is stopped", %{
    authenticated_conn: conn
  } do
    on_exit(&restart_coordinator/0)

    assert :ok =
             Supervisor.terminate_child(
               GSMLG.ProxyRules.Supervisor,
               Coordinator
             )

    conn = get(conn, ~p"/proxy-rules/sources/gfwlist")

    assert json_response(conn, 503) == %{
             "error" => %{
               "code" => "not_available",
               "message" => "Proxy rule source service is unavailable"
             }
           }
  end

  test "rejects a source line that cannot fit in a bounded page", %{
    authenticated_conn: conn
  } do
    replace_remote(source_snapshot(:remote, String.duplicate("x", 256 * 1024), %{}))
    conn = get(conn, ~p"/proxy-rules/sources/gfwlist?limit=1")

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "page_too_large",
               "message" => "A source line exceeds the maximum page size"
             }
           }
  end

  defp replace_sources(remote, local_proxy, local_direct) do
    :sys.replace_state(Coordinator, fn state ->
      %{state | remote: remote, local_proxy: local_proxy, local_direct: local_direct}
    end)
  end

  defp replace_remote(remote) do
    :sys.replace_state(Coordinator, fn state -> %{state | remote: remote} end)
  end

  defp source_snapshot(kind, content, metadata) do
    {line_count, line_checkpoints} = SourceSnapshot.line_metadata(content)

    %SourceSnapshot{
      kind: kind,
      content: content,
      content_sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      observed_at: ~U[2026-08-03 00:00:00Z],
      line_count: line_count,
      line_checkpoints: line_checkpoints,
      metadata: metadata,
      availability: :ready
    }
  end

  defp restart_coordinator do
    case Supervisor.restart_child(GSMLG.ProxyRules.Supervisor, Coordinator) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end
  end
end
