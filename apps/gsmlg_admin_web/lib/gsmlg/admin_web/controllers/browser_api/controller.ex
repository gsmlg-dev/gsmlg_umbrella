defmodule GSMLG.AdminWeb.BrowserAPI.Controller do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.AdminWeb.BrowserAPI.{ArtifactDownload, Presenter, Request, Response}
  alias GSMLG.AdminWeb.BrowserAudit
  alias GSMLG.Browser
  alias GSMLG.Browser.Error
  alias OpenApiSpex.OpenApi

  @catalog_profile "https://www.rfc-editor.org/info/rfc9727"

  def nodes(conn, _params) do
    with :ok <- Request.empty_query(conn.query_params) do
      render_result(conn, Browser.list_nodes(actor(conn), []), 200, fn nodes ->
        list(nodes, &Presenter.node/1)
      end)
    else
      error -> render_error(conn, error)
    end
  end

  def node(conn, %{"node_id" => id}) do
    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.get_node(actor(conn), id), 200, &Presenter.node/1)
    else
      error -> render_error(conn, error)
    end
  end

  def profiles(conn, %{"node_id" => node_id}) do
    with :ok <- Request.empty_query(conn.query_params),
         {:ok, node_id} <- Request.id(node_id) do
      render_result(
        conn,
        Browser.list_profiles(actor(conn), node_id, []),
        200,
        fn profiles -> list(profiles, &Presenter.profile/1) end
      )
    else
      error -> render_error(conn, error)
    end
  end

  def sync_profiles(conn, %{"node_id" => node_id}) do
    audit = audit("profiles.sync", "node", node_id)

    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, node_id} <- Request.id(node_id) do
      render_result(
        conn,
        Browser.sync_profiles(actor(conn), node_id),
        200,
        fn profiles -> list(profiles, &Presenter.profile/1) end,
        audit
      )
    else
      error -> render_error(conn, error, audit)
    end
  end

  def configure_profile(conn, %{"id" => id}) do
    audit = audit("profile.configure", "profile", id)

    with :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id),
         {:ok, attrs} <- Request.profile_configuration(conn.body_params) do
      render_result(
        conn,
        Browser.configure_profile(actor(conn), id, attrs),
        200,
        &Presenter.profile/1,
        audit
      )
    else
      error -> render_error(conn, error, audit)
    end
  end

  def launch_profile(conn, %{"id" => id}),
    do: profile_mutation(conn, id, "profile.launch", &Browser.launch_profile/2)

  def stop_profile(conn, %{"id" => id}),
    do: profile_mutation(conn, id, "profile.stop", &Browser.stop_profile/2)

  def create_session(conn, _params) do
    audit = audit("session.create", "session", nil)

    with :ok <- Request.empty_query(conn.query_params),
         {:ok, attrs} <- Request.session(conn.body_params) do
      render_result(
        conn,
        Browser.create_session(actor(conn), attrs),
        201,
        &Presenter.session/1,
        audit
      )
    else
      error -> render_error(conn, error, audit)
    end
  end

  def session(conn, %{"id" => id}) do
    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.get_session(actor(conn), id), 200, &Presenter.session/1)
    else
      error -> render_error(conn, error)
    end
  end

  def observe_session(conn, %{"id" => id}) do
    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.observe_session(actor(conn), id), 200, fn result ->
        result |> field(:observation) |> Presenter.observation()
      end)
    else
      error -> render_error(conn, error)
    end
  end

  def session_action(conn, %{"id" => id}) do
    audit = audit("session.action", "session", id)

    with :ok <- Request.empty_query(conn.query_params),
         {:ok, action} <- Request.action(id, conn.body_params),
         {:ok, id} <- Request.id(id) do
      render_result(
        conn,
        Browser.execute_action(actor(conn), id, action),
        200,
        fn result -> result |> field(:result) |> Presenter.action_result() end,
        audit
      )
    else
      error -> render_error(conn, error, audit)
    end
  end

  def manual_acquire(conn, %{"id" => id}),
    do: session_mutation(conn, id, "session.manual_acquire", &Browser.manual_acquire/2)

  def manual_release(conn, %{"id" => id}),
    do: session_mutation(conn, id, "session.manual_release", &Browser.manual_release/2)

  def delete_session(conn, %{"id" => id}) do
    audit = audit("session.close", "session", id)

    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.close_session(actor(conn), id), 204, :no_content, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  def create_job(conn, _params) do
    audit = audit("job.create", "job", nil)

    with :ok <- Request.empty_query(conn.query_params),
         {:ok, attrs} <- Request.job(conn.body_params) do
      render_result(conn, Browser.create_job(actor(conn), attrs), 202, &Presenter.job/1, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  def jobs(conn, _params) do
    with {:ok, opts} <- Request.pagination(conn.query_params, :uuid) do
      render_result(conn, Browser.list_jobs(actor(conn), opts), 200, fn jobs ->
        paginated(jobs, opts, &Presenter.job/1, &field(&1, :id))
      end)
    else
      error -> render_error(conn, error)
    end
  end

  def job(conn, %{"id" => id}) do
    with :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.get_job(actor(conn), id), 200, &Presenter.job/1)
    else
      error -> render_error(conn, error)
    end
  end

  def job_events(conn, %{"id" => id}) do
    with {:ok, id} <- Request.id(id),
         {:ok, opts} <- Request.pagination(conn.query_params, :sequence) do
      facade_opts = [limit: opts[:limit], after_sequence: opts[:after]]

      render_result(conn, Browser.list_job_events(actor(conn), id, facade_opts), 200, fn events ->
        paginated(events, opts, &Presenter.event/1, &field(&1, :sequence))
      end)
    else
      error -> render_error(conn, error)
    end
  end

  def cancel_job(conn, %{"id" => id}),
    do: job_control(conn, id, "job.cancel", &Browser.cancel_job/2, :empty)

  def retry_job(conn, %{"id" => id}),
    do: job_control(conn, id, "job.retry", &Browser.retry_job/3, :retry)

  def resume_job(conn, %{"id" => id}),
    do: job_control(conn, id, "job.resume", &Browser.resume_job/2, :empty)

  def reconcile_job(conn, %{"id" => id}),
    do: job_control(conn, id, "job.reconcile", &Browser.reconcile_job/2, :empty)

  def job_artifacts(conn, %{"id" => id}) do
    with {:ok, id} <- Request.id(id),
         {:ok, opts} <- Request.pagination(conn.query_params, :uuid) do
      render_result(conn, Browser.list_artifacts(actor(conn), id, opts), 200, fn artifacts ->
        paginated(artifacts, opts, &Presenter.artifact/1, &field(&1, :id))
      end)
    else
      error -> render_error(conn, error)
    end
  end

  def artifact(conn, %{"id" => id}) do
    with :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, Browser.get_artifact(actor(conn), id), 200, &Presenter.artifact/1)
    else
      error -> render_error(conn, error)
    end
  end

  def artifact_content(conn, %{"id" => id}) do
    with :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      ArtifactDownload.send(conn, actor(conn), id)
    else
      error -> render_error(conn, error)
    end
  end

  def openapi(conn, _params) do
    with :ok <- Request.empty_query(conn.query_params) do
      document = GSMLG.AdminWeb.BrowserApiSpec.spec() |> OpenApi.to_map()
      Response.json(conn, 200, document)
    else
      error -> render_error(conn, error)
    end
  end

  def catalog(conn, _params) do
    with :ok <- Request.empty_query(conn.query_params) do
      body = %{
        "linkset" => [
          %{
            "anchor" => "/api/browser",
            "service-desc" => [
              %{"href" => "/api/browser/openapi.json", "type" => "application/json"}
            ]
          }
        ]
      }

      conn
      |> put_resp_header(
        "content-type",
        ~s(application/linkset+json; profile="#{@catalog_profile}")
      )
      |> put_resp_header("link", ~s(</.well-known/api-catalog>; rel="api-catalog"))
      |> Response.security_headers()
      |> send_resp(200, JSON.encode!(body))
    else
      error -> render_error(conn, error)
    end
  end

  defp profile_mutation(conn, id, operation, facade) do
    audit = audit(operation, "profile", id)

    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, facade.(actor(conn), id), 200, &Presenter.profile/1, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  defp session_mutation(conn, id, operation, facade) do
    audit = audit(operation, "session", id)

    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, facade.(actor(conn), id), 200, &Presenter.session/1, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  defp job_control(conn, id, operation, facade, :empty) do
    audit = audit(operation, "job", id)

    with :ok <- Request.empty(conn.body_params),
         :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id) do
      render_result(conn, facade.(actor(conn), id), 202, &Presenter.job/1, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  defp job_control(conn, id, operation, facade, :retry) do
    audit = audit(operation, "job", id)

    with :ok <- Request.empty_query(conn.query_params),
         {:ok, id} <- Request.id(id),
         {:ok, %{idempotency_key: key}} <- Request.retry(conn.body_params) do
      render_result(conn, facade.(actor(conn), id, key), 202, &Presenter.job/1, audit)
    else
      error -> render_error(conn, error, audit)
    end
  end

  defp render_result(conn, result, status, presenter, audit \\ nil)

  defp render_result(conn, {:ok, value}, 204, :no_content, audit) do
    record_audit(conn, audit, "accepted", value)
    Response.no_content(conn)
  end

  defp render_result(conn, {:ok, value}, status, presenter, audit)
       when is_function(presenter, 1) do
    record_audit(conn, audit, "accepted", value)
    Response.json(conn, status, presenter.(value))
  end

  defp render_result(conn, error, _status, _presenter, audit),
    do: render_error(conn, error, audit)

  defp render_error(conn, error, audit \\ nil)

  defp render_error(conn, {:error, %Error{} = error}, audit) do
    record_audit(conn, audit, "rejected", nil, error.code)
    Response.from_browser(conn, error)
  end

  defp render_error(conn, {:error, code}, audit) when is_binary(code) do
    record_audit(conn, audit, "rejected", nil, code)
    request_error(conn, code)
  end

  defp render_error(conn, _invalid, audit) do
    record_audit(conn, audit, "failed", nil, "browser_internal_error")

    Response.error(
      conn,
      500,
      "internal",
      "browser_internal_error",
      "The Browser operation could not be completed.",
      false,
      nil
    )
  end

  defp request_error(conn, "invalid_query") do
    Response.error(
      conn,
      422,
      "request",
      "invalid_query",
      "The Browser query is invalid.",
      false,
      "correct_request"
    )
  end

  defp request_error(conn, code) when code in ["invalid_request", "invalid_action"] do
    class = if code == "invalid_action", do: "action", else: "request"

    Response.error(
      conn,
      422,
      class,
      code,
      "The Browser request is invalid.",
      false,
      "correct_request"
    )
  end

  defp list(values, presenter) when is_list(values), do: %{data: Enum.map(values, presenter)}

  defp paginated(values, opts, presenter, cursor_fun) when is_list(values) do
    %{data: Enum.map(values, presenter), page: Presenter.page(values, opts, cursor_fun)}
  end

  defp audit(operation, resource_type, resource_id),
    do: [operation: operation, resource_type: resource_type, resource_id: resource_id]

  defp record_audit(conn, audit, outcome, value, error_code \\ nil)

  defp record_audit(_conn, nil, _outcome, _value, _error_code), do: :ok

  defp record_audit(conn, audit, outcome, value, error_code) do
    resource_id = audit[:resource_id] || field(value, :id)

    BrowserAudit.record(conn, audit[:operation], outcome, %{
      resource_type: audit[:resource_type],
      resource_id: resource_id,
      error_code: error_code
    })
  end

  defp actor(conn), do: conn.assigns.actor
  defp field(%_{} = value, key), do: Map.get(value, key)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  defp field(_value, _key), do: nil
end
