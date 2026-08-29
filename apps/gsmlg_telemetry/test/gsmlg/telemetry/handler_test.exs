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
      metadata_params: "METADATA-PARAMS-SENTINEL",
      metadata_session: "METADATA-SESSION-SENTINEL",
      metadata_headers: "METADATA-HEADERS-SENTINEL",
      metadata_socket: "METADATA-SOCKET-SENTINEL"
    }

    conn =
      Plug.Test.conn(:post, "/admin/sign-in", %{"password" => sentinels.password})
      |> Plug.Conn.put_req_header("x-client-cert-certificate-pem", sentinels.certificate)
      |> Plug.Conn.put_req_header("x-client-cert-subject", sentinels.subject)
      |> Plug.Conn.put_req_header("x-client-cert-email", sentinels.email)
      |> Plug.Conn.assign(:client_certificate, sentinels.assigned_certificate)
      |> Map.update!(:private, fn private ->
        Map.put(private, :plug_session, %{
          "guardian_default_token" => sentinels.guardian_token
        })
      end)

    metadata = %{
      conn: conn,
      headers: %{client_certificate: sentinels.metadata_headers},
      method: "POST",
      params: %{password: sentinels.metadata_params},
      request_id: "request-123",
      request_path: "/admin/sign-in",
      session: %{token: sentinels.metadata_session},
      socket: %{assigns: sentinels.metadata_socket},
      status: 200
    }

    Handler.handle_event([:phoenix, :endpoint, :stop], %{duration: 1}, metadata, %{})

    assert {[:phoenix, :endpoint, :stop], %{duration: 1}, reported_metadata, _timestamp} =
             reported_event([:phoenix, :endpoint, :stop])

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

  test "applies bounded metadata whitelists to every infrastructure event family" do
    sensitive_metadata = %{
      conn: %{secret: "INFRA-CONN-SENTINEL"},
      headers: [authorization: "INFRA-HEADERS-SENTINEL"],
      params: %{password: "INFRA-PARAMS-SENTINEL"},
      path_params: %{id: "INFRA-PATH-PARAMS-SENTINEL"},
      query: "INFRA-QUERY-SENTINEL",
      result: {:ok, "INFRA-RESULT-SENTINEL"},
      session: %{token: "INFRA-SESSION-SENTINEL"},
      socket: %{assigns: "INFRA-SOCKET-SENTINEL"}
    }

    event_cases = [
      {[:phoenix, :endpoint, :start],
       %{
         method: "GET",
         request_id: "request-start",
         request_path: "/admin",
         status: 101
       }},
      {[:phoenix, :router_dispatch, :start],
       %{route: "/admin/:id", plug: GSMLG.AdminWeb.Router, plug_opts: :show, action: :show}},
      {[:phoenix, :router_dispatch, :stop],
       %{route: "/admin/:id", plug: GSMLG.AdminWeb.Router, plug_opts: :show, action: :show}},
      {[:phoenix, :live_view, :mount, :start],
       %{view: GSMLG.AdminWeb.GaoNoteLive.Index, action: :index}},
      {[:phoenix, :live_view, :mount, :stop],
       %{view: GSMLG.AdminWeb.GaoNoteLive.Index, action: :index}},
      {[:phoenix, :live_view, :handle_params, :start],
       %{view: GSMLG.AdminWeb.GaoNoteLive.Index, action: :index}},
      {[:phoenix, :live_view, :handle_params, :stop],
       %{view: GSMLG.AdminWeb.GaoNoteLive.Index, action: :index}},
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
