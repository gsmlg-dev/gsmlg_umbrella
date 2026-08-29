defmodule GSMLG.Telemetry.HandlerTest do
  use ExUnit.Case, async: false

  alias GSMLG.Telemetry.{Handler, Reporter}

  setup do
    reporter_state = :sys.get_state(Reporter)
    :ets.delete_all_objects(reporter_state.buffer)
    :ok
  end

  test "redacts sensitive Phoenix endpoint metadata before reporting" do
    sentinels = %{
      certificate: "CERTIFICATE-DER-SENTINEL",
      subject: "CERTIFICATE-SUBJECT-SENTINEL",
      email: "CERTIFICATE-EMAIL-SENTINEL",
      password: "PASSWORD-SENTINEL",
      assigned_certificate: "ASSIGNED-CERTIFICATE-SENTINEL",
      guardian_token: "GUARDIAN-TOKEN-SENTINEL",
      options: "ENDPOINT-OPTIONS-SENTINEL"
    }

    conn =
      Plug.Test.conn(:post, "/admin/sign-in", %{"password" => sentinels.password})
      |> Plug.Conn.put_req_header("x-client-cert-certificate-pem", sentinels.certificate)
      |> Plug.Conn.put_req_header("x-client-cert-subject", sentinels.subject)
      |> Plug.Conn.put_req_header("x-client-cert-email", sentinels.email)
      |> Plug.Conn.assign(:client_certificate, sentinels.assigned_certificate)
      |> Plug.Conn.put_resp_header("x-request-id", "request-123")
      |> Map.update!(:private, fn private ->
        Map.put(private, :plug_session, %{
          "guardian_default_token" => sentinels.guardian_token
        })
      end)
      |> Map.put(:status, 200)

    metadata = %{
      conn: conn,
      options: %{log: sentinels.options}
    }

    Enum.each([:start, :stop], fn phase ->
      event_name = [:phoenix, :endpoint, phase]
      Handler.handle_event(event_name, %{duration: 1}, metadata, %{})

      assert {^event_name, %{duration: 1}, reported_metadata, _timestamp} =
               reported_event(event_name)

      assert reported_metadata == %{
               method: "POST",
               request_id: "request-123",
               request_path: "/admin/sign-in",
               status: 200
             }

      inspected_metadata = inspect(reported_metadata)

      Enum.each(sentinels, fn {_name, sentinel} ->
        refute inspected_metadata =~ sentinel
      end)
    end)
  end

  test "redacts Ecto query params and results before reporting" do
    sentinels = %{
      der: "ECTO-CERTIFICATE-DER-SENTINEL",
      subject: "ECTO-CERTIFICATE-SUBJECT-SENTINEL",
      email: "ECTO-CERTIFICATE-EMAIL-SENTINEL",
      query: "ECTO-QUERY-SENTINEL",
      options: "ECTO-OPTIONS-SENTINEL"
    }

    metadata = %{
      options: [telemetry_options: sentinels.options],
      params: [sentinels.der, sentinels.subject, sentinels.email],
      query: sentinels.query,
      repo: GSMLG.Repo,
      result: {:ok, %{subject: sentinels.subject, email: sentinels.email}},
      source: "user_client_certificates",
      type: :ecto_sql_query
    }

    Handler.handle_event([:ecto, :repo, :query], %{total_time: 1}, metadata, %{})

    assert {[:ecto, :repo, :query], %{total_time: 1}, reported_metadata, _timestamp} =
             reported_event([:ecto, :repo, :query])

    assert reported_metadata == %{
             repo: GSMLG.Repo,
             source: "user_client_certificates",
             type: :ecto_sql_query
           }

    inspected_metadata = inspect(reported_metadata)

    Enum.each(sentinels, fn {_name, sentinel} ->
      refute inspected_metadata =~ sentinel
    end)
  end

  test "redacts metadata from an actual GSMLG Repo query" do
    event_name = [:gsmlg, :repo, :query]
    test_handler_id = :gsmlg_repo_query_privacy_test_handler

    sentinels = [
      "REPO-CERTIFICATE-DER-SENTINEL",
      "REPO-CERTIFICATE-SUBJECT-SENTINEL",
      "REPO-CERTIFICATE-EMAIL-SENTINEL"
    ]

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GSMLG.Repo)

    unless main_handler_attached?(event_name) do
      :ok = :telemetry.attach(test_handler_id, event_name, &Handler.handle_event/4, %{})
      on_exit(fn -> :telemetry.detach(test_handler_id) end)
    end

    reporter_state = :sys.get_state(Reporter)
    :ets.delete_all_objects(reporter_state.buffer)

    result =
      GSMLG.Repo.query!(
        "SELECT $1::text AS der, $2::text AS subject, $3::text AS email",
        sentinels
      )

    assert [^sentinels] = result.rows

    assert {^event_name, _measurements, reported_metadata, _timestamp} =
             reported_event(event_name)

    assert reported_metadata == %{
             repo: GSMLG.Repo,
             source: nil,
             type: :ecto_sql_query
           }

    refute Enum.any?(sentinels, &(inspect(reported_metadata) =~ &1))
    refute Map.has_key?(reported_metadata, :query)
    refute Map.has_key?(reported_metadata, :params)
    refute Map.has_key?(reported_metadata, :result)
    refute Map.has_key?(reported_metadata, :options)

    assert main_handler_attached?(event_name)
  end

  test "derives bounded LiveView metadata from the socket" do
    sentinel = "LIVEVIEW-SENSITIVE-SENTINEL"

    socket = %Phoenix.LiveView.Socket{
      view: GSMLG.AdminWeb.GaoNoteLive.Index,
      assigns: %{__changed__: %{}, live_action: :index, token: sentinel}
    }

    metadata = %{
      socket: socket,
      params: %{"token" => sentinel},
      session: %{"guardian_default_token" => sentinel},
      uri: "https://example.com/admin?token=#{sentinel}"
    }

    event_names = [
      [:phoenix, :live_view, :mount, :start],
      [:phoenix, :live_view, :mount, :stop],
      [:phoenix, :live_view, :handle_params, :start],
      [:phoenix, :live_view, :handle_params, :stop]
    ]

    Enum.each(event_names, fn event_name ->
      Handler.handle_event(event_name, %{duration: 1}, metadata, %{})

      assert {^event_name, %{duration: 1}, reported_metadata, _timestamp} =
               reported_event(event_name)

      assert reported_metadata == %{
               view: GSMLG.AdminWeb.GaoNoteLive.Index,
               action: :index
             }

      refute inspect(reported_metadata) =~ sentinel
    end)
  end

  test "applies bounded metadata whitelists to router and query event families" do
    conn =
      Plug.Test.conn(:get, "/admin/123")
      |> Plug.Conn.put_req_header("authorization", "INFRA-CONN-SENTINEL")

    sensitive_metadata = %{
      conn: conn,
      headers: [authorization: "INFRA-HEADERS-SENTINEL"],
      params: %{password: "INFRA-PARAMS-SENTINEL"},
      path_params: %{id: "INFRA-PATH-PARAMS-SENTINEL"},
      query: "INFRA-QUERY-SENTINEL",
      result: {:ok, "INFRA-RESULT-SENTINEL"},
      session: %{token: "INFRA-SESSION-SENTINEL"},
      socket: %{assigns: "INFRA-SOCKET-SENTINEL"}
    }

    event_cases = [
      {[:phoenix, :router_dispatch, :start],
       %{route: "/admin/:id", plug: GSMLG.AdminWeb.Router, plug_opts: :show, action: :show}},
      {[:phoenix, :router_dispatch, :stop],
       %{route: "/admin/:id", plug: GSMLG.AdminWeb.Router, plug_opts: :show, action: :show}},
      {[:phoenix, :repo, :query],
       %{repo: GSMLG.Repo, source: "user_client_certificates", type: :ecto_sql_query}},
      {[:ecto, :db, :query],
       %{repo: GSMLG.Repo, source: "user_client_certificates", type: :ecto_sql_query}}
    ]

    Enum.each(event_cases, fn {event_name, safe_metadata} ->
      Handler.handle_event(
        event_name,
        %{duration: 1},
        Map.merge(sensitive_metadata, safe_metadata),
        %{}
      )

      assert {^event_name, %{duration: 1}, reported_metadata, _timestamp} =
               reported_event(event_name)

      assert reported_metadata == safe_metadata
    end)
  end

  test "rejects oversized binaries, composites, and non-module router plug values" do
    route = String.duplicate("r", 512)

    Handler.handle_event(
      [:phoenix, :router_dispatch, :stop],
      %{duration: 1},
      %{
        action: [:index],
        plug: "Elixir.UnsafePlug",
        plug_opts: %{action: :index},
        route: route
      },
      %{}
    )

    assert {[:phoenix, :router_dispatch, :stop], _measurements, reported_metadata, _timestamp} =
             reported_event([:phoenix, :router_dispatch, :stop])

    assert reported_metadata == %{route: route}

    Handler.handle_event(
      [:phoenix, :router_dispatch, :start],
      %{duration: 1},
      %{route: String.duplicate("r", 513)},
      %{}
    )

    assert {[:phoenix, :router_dispatch, :start], _measurements, %{}, _timestamp} =
             reported_event([:phoenix, :router_dispatch, :start])
  end

  test "preserves metadata for explicit custom events" do
    metadata = %{
      domain: %{operation: :certificate_login},
      message: "custom telemetry metadata",
      tags: [:authentication, :admin]
    }

    Handler.handle_event([:gsmlg, :log], %{count: 1}, metadata, %{})

    assert {[:gsmlg, :log], %{count: 1}, ^metadata, _timestamp} =
             reported_event([:gsmlg, :log])
  end

  test "bounds and redacts sensitive custom event metadata before reporting" do
    sentinel = "CUSTOM-SENSITIVE-SENTINEL"
    [port | _other_ports] = Port.list()

    conn =
      Plug.Test.conn(:post, "/admin/sign-in", %{"password" => sentinel})
      |> Plug.Conn.put_req_header("authorization", sentinel)
      |> Plug.Conn.put_req_header("cookie", sentinel)
      |> Plug.Conn.put_req_header("x-client-cert-certificate-pem", sentinel)
      |> Plug.Conn.assign(:client_certificate, sentinel)

    metadata = %{
      "PASSWORD_CONFIRMATION" => sentinel,
      domain: %{operation: :certificate_login, token: sentinel},
      tags: [:authentication, :admin],
      message: "safe",
      password: sentinel,
      token: sentinel,
      authorization: sentinel,
      cookie: sentinel,
      session: %{token: sentinel},
      certificate: sentinel,
      certificate_der: sentinel,
      pem: sentinel,
      params: %{password: sentinel},
      body_params: %{password: sentinel},
      headers: [{"authorization", sentinel}],
      conn: conn,
      socket: %{assigns: %{token: sentinel}},
      assigns: %{client_certificate: sentinel},
      private: %{guardian_token: sentinel},
      query: "SELECT #{sentinel}",
      result: {:ok, sentinel},
      process: self(),
      port: port,
      reference: make_ref(),
      callback: fn -> sentinel end,
      structured: URI.parse("https://example.com/#{sentinel}"),
      oversized: String.duplicate("x", 513),
      invalid_binary: <<255>>
    }

    Handler.handle_event([:gsmlg, :log], %{count: 1}, metadata, %{})

    assert {[:gsmlg, :log], %{count: 1}, reported_metadata, _timestamp} =
             reported_event([:gsmlg, :log])

    assert reported_metadata == %{
             domain: %{operation: :certificate_login},
             tags: [:authentication, :admin],
             message: "safe"
           }

    refute inspect(reported_metadata) =~ sentinel
  end

  test "bounds custom event map size, list length, and nesting depth" do
    max_map = Map.new(1..32, &{"key-#{&1}", &1})

    metadata = %{
      max_map: max_map,
      max_list: Enum.to_list(1..32),
      oversized_map: Map.put(max_map, "key-33", 33),
      oversized_list: Enum.to_list(1..33),
      within_depth: %{one: %{two: %{three: :safe}}},
      too_deep: %{one: %{two: %{three: %{four: :dropped}}}}
    }

    Handler.handle_event([:custom, :bounded], %{count: 1}, metadata, %{})

    assert {[:custom, :bounded], %{count: 1}, reported_metadata, _timestamp} =
             reported_event([:custom, :bounded])

    assert reported_metadata.max_map == max_map
    assert reported_metadata.max_list == Enum.to_list(1..32)
    assert reported_metadata.within_depth == %{one: %{two: %{three: :safe}}}
    refute Map.has_key?(reported_metadata, :oversized_map)
    refute Map.has_key?(reported_metadata, :oversized_list)
    assert get_in(reported_metadata, [:too_deep, :one, :two, :three]) == nil
  end

  test "Phoenix filters authentication and certificate parameters" do
    params =
      Map.new(~w(password password_confirmation token certificate), fn key ->
        {key, "sensitive-value"}
      end)

    assert Phoenix.Logger.filter_values(params) ==
             Map.new(Map.keys(params), &{&1, "[FILTERED]"})
  end

  defp reported_event(event_name) do
    reporter_state = :sys.get_state(Reporter)

    Enum.find(:ets.tab2list(reporter_state.buffer), fn
      {^event_name, _measurements, _metadata, _timestamp} -> true
      _event -> false
    end)
  end

  defp main_handler_attached?(event_name) do
    Enum.any?(:telemetry.list_handlers(event_name), fn handler ->
      handler.id == :gsmlg_telemetry_main_handler and handler.event_name == event_name
    end)
  end
end
