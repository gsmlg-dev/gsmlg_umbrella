defmodule GSMLG.AdminWeb.Router do
  use GSMLG.AdminWeb, :router

  pipeline :maybe_browser_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLG.AdminWeb.Guardian,
      error_handler: GSMLG.AdminWeb.Guardian.OptionalWebAuthErrorHandler
    )

    plug(Guardian.Plug.VerifySession, halt: false)
    plug(Guardian.Plug.LoadResource, allow_blank: true)
  end

  pipeline :maybe_api_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLG.AdminWeb.Guardian,
      error_handler: GSMLG.AdminWeb.Guardian.ApiAuthErrorHandler
    )

    # plug(Guardian.Plug.VerifyHeader, halt: false)
    plug(Guardian.Plug.LoadResource, allow_blank: true)
  end

  pipeline :client_certificate_browser_auth do
    plug(GSMLG.AdminWeb.Plugs.ClientCertificateAuth)
  end

  pipeline :ensure_authed_access do
    plug(Guardian.Plug.EnsureAuthenticated, claims: %{"typ" => "access"})
    plug(:ensure_session_process_started)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(Phoenix.SessionProcess.SessionId)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {GSMLG.AdminWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(GSMLG.AdminWeb.Plugs.FetchCurrentScope)
  end

  pipeline :browser_json do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(Phoenix.SessionProcess.SessionId)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {GSMLG.AdminWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(GSMLG.AdminWeb.Plugs.FetchCurrentScope)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :admin_bearer_auth do
    plug(GSMLG.AdminWeb.Plugs.AdminBearerAuth)
  end

  pipeline :browser_bearer_auth do
    plug(GSMLG.AdminWeb.Plugs.BrowserBearerAuth)
  end

  pipeline :mcp_admin_api do
    plug(:accepts, ["json"])
    plug(GSMLG.AdminWeb.Plugs.GaoNoteMCPAuth)
    plug(GSMLG.AdminWeb.Plugs.VerifyMCPOrigin)
  end

  # oauth2 authentication, not set yet
  # scope "/auth", GSMLG.AdminWeb do
  #   pipe_through :browser

  #   get("/:provider", AuthController, :request)
  #   get("/:provider/callback", AuthController, :callback)
  # end

  scope "/", GSMLG.AdminWeb do
    pipe_through([:browser, :maybe_browser_auth, :client_certificate_browser_auth])

    get("/sign_in", AuthController, :index)
    post("/sign_in", AuthController, :sign_in)

    get("/sign_up", AuthController, :new)
    post("/sign_up", AuthController, :sign_up)
  end

  scope "/api", GSMLG.AdminWeb do
    pipe_through(:admin_bearer_auth)

    get(
      "/gao_notes/:note_id/attachments/*path",
      GaoNoteAttachmentContentController,
      :show
    )
  end

  scope "/", GSMLG.AdminWeb do
    pipe_through([
      :browser,
      :maybe_browser_auth,
      :client_certificate_browser_auth,
      :ensure_authed_access
    ])

    delete("/sign_out", AuthController, :sign_out)

    get("/", PageController, :index)

    get("/node_management", NodeManagementController, :index)
    post("/node_management", NodeManagementController, :update)

    get(
      "/gao_notes/notes/:note_id/attachments/*path",
      GaoNoteAttachmentContentController,
      :show
    )

    live("/blogs", BlogLive.Index, :index)
    live("/blogs/import", BlogLive.Import, :import)
    live("/blogs/new", BlogLive.Index, :new)
    live("/blogs/settings", BlogLive.Index, :settings)
    live("/blogs/:id", BlogLive.Index, :show)
    live("/blogs/:id/edit", BlogLive.Index, :edit)
    live("/blogs/:id/translations", BlogLive.TranslationLive.Index, :index)

    live("/gao_notes", GaoNoteLive.DashboardLive, :index)
    live("/gao_notes/notes", GaoNoteLive.Index, :index)
    live("/gao_notes/notes/new", GaoNoteLive.Index, :new)
    live("/gao_notes/notes/:id/show", GaoNoteLive.Index, :show)
    live("/gao_notes/notes/:id/edit", GaoNoteLive.Index, :edit)
    live("/gao_notes/label_settings", GaoNoteLive.LabelSettingLive.Index, :index)
    live("/gao_notes/recycle_bin", GaoNoteLive.RecycleBinLive.Index, :index)
    live("/gao_notes/logs", GaoNoteLive.LogLive.Index, :index)
    live("/gao_notes/mcp", GaoNoteLive.MCPLive.Index, :index)

    live("/users", UserLive.Index, :index)
    live("/users/new", UserLive.Index, :new)
    live("/users/:id", UserLive.Index, :show)
    live("/users/:id/edit", UserLive.Index, :edit)
    live("/users/:id/reset_password", UserLive.Index, :reset_password)

    live("/user_tokens", UserTokenLive.Index, :index)
    live("/user_tokens/new", UserTokenLive.Index, :new)
    live("/user_tokens/:id/edit", UserTokenLive.Index, :edit)
    live("/user_tokens/:id", UserTokenLive.Index, :show)

    live("/api_providers", ApiProviderLive.Index, :index)
    live("/api_providers/new", ApiProviderLive.Index, :new)
    live("/api_providers/:id/edit", ApiProviderLive.Index, :edit)
    live("/api_providers/:id", ApiProviderLive.Index, :show)

    live("/web_push", WebPushLive.Index, :index)

    # Commander Management Routes
    get("/commander", GaoNoteRedirectController, :commander_list)
    live("/commander/list", CommanderLive.ListLive, :index)
    live("/commander/tokens", CommanderLive.TokensLive, :index)
    live("/commander/tokens/new", CommanderLive.TokensLive, :new)
    live("/commander/:name/overview", CommanderLive.ShowLive, :overview)
    live("/commander/:name/shell", CommanderLive.ShowLive, :shell)
    live("/commander/:name/browser", BrowserLive.Index, :commander)

    # Remote Browser Control
    live("/browser", BrowserLive.Index, :dashboard)
    live("/browser/nodes", BrowserLive.Index, :nodes)
    live("/browser/profiles", BrowserLive.Index, :profiles)
    live("/browser/sessions", BrowserLive.Index, :sessions)
    live("/browser/jobs", BrowserLive.Index, :jobs)
    live("/browser/jobs/new", BrowserLive.Index, :new_job)
    live("/browser/jobs/:id", BrowserLive.Index, :job)
    live("/browser/settings", BrowserLive.Index, :settings)
    get("/browser/artifacts/:id/content", BrowserArtifactContentController, :show)

    live("/scout", ScoutLive.DashboardLive, :index)
    live("/proxy-rules", ProxyRulesLive.Index, :index)

    live("/github", GithubLive.Index, :index)

    live("/aws/route53/hosted_zones", Route53Live.Index, :list_zones)
    live("/aws/route53/hosted_zones/:id/records", Route53Live.Index, :list_records)

    live("/aws/dynamo_db", DynamoDBLive.Index, :index)
    live("/aws/dynamo_db/:table/scan", DynamoDBLive.Index, :scan)

    live("/aws/s3/buckets", S3Live.Index, :list_buckets)

    # Storage Management
    live("/storage", StorageLive.Index, :index)
    live("/storage/config", StorageLive.Config, :index)
    live("/storage/:id", StorageLive.Show, :show)

    # Caddy Management Routes
    live("/caddy", CaddyLive.DashboardLive, :index)
    live("/caddy/config", CaddyLive.ConfigLive, :index)
    live("/caddy/server", CaddyLive.ServerLive, :index)
    live("/caddy/server/settings", CaddyLive.ServerSettingsLive, :index)
    live("/caddy/metrics", CaddyLive.MetricsLive, :index)
    live("/caddy/runtime", CaddyLive.RuntimeLive, :index)
    live("/caddy/logs", CaddyLive.LogsLive, :index)

    import Phoenix.LiveDashboard.Router

    live_dashboard("/live_dashboard",
      metrics: GSMLG.AdminWeb.Telemetry,
      ecto_repos: [GSMLG.Repo],
      ecto_psql_extras_options: [{GSMLG.Repo, [lang: :en]}]
    )
  end

  scope "/", GSMLG.AdminWeb do
    pipe_through([:browser_json, :maybe_browser_auth, :ensure_authed_access])

    get("/proxy-rules/sources/:source", ProxyRulesSourceController, :show)
  end

  scope "/api", GSMLG.AdminWeb do
    pipe_through([:api, :maybe_api_auth])

    post("/sign_in", AuthController, :sign_in)
    post("/sign_up", AuthController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:id", BlogController, :show)
  end

  scope "/api/scout", GSMLG.AdminWeb do
    pipe_through([:api, :admin_bearer_auth])

    post("/fetch", ScoutFetchController, :create)
    post("/fetch/sync", ScoutFetchController, :sync)
    get("/fetch/:job_id", ScoutFetchController, :show)
  end

  scope "/api/browser", GSMLG.AdminWeb.BrowserAPI do
    pipe_through([:api, :browser_bearer_auth])

    get("/nodes", Controller, :nodes)
    get("/nodes/:node_id", Controller, :node)
    get("/nodes/:node_id/profiles", Controller, :profiles)
    post("/nodes/:node_id/profiles/sync", Controller, :sync_profiles)
    patch("/profiles/:id", Controller, :configure_profile)
    post("/profiles/:id/launch", Controller, :launch_profile)
    post("/profiles/:id/stop", Controller, :stop_profile)

    post("/sessions", Controller, :create_session)
    get("/sessions/:id", Controller, :session)
    post("/sessions/:id/observe", Controller, :observe_session)
    post("/sessions/:id/actions", Controller, :session_action)
    post("/sessions/:id/manual-acquire", Controller, :manual_acquire)
    post("/sessions/:id/manual-release", Controller, :manual_release)
    delete("/sessions/:id", Controller, :delete_session)

    post("/jobs", Controller, :create_job)
    get("/jobs", Controller, :jobs)
    get("/jobs/:id", Controller, :job)
    get("/jobs/:id/events", Controller, :job_events)
    post("/jobs/:id/cancel", Controller, :cancel_job)
    post("/jobs/:id/retry", Controller, :retry_job)
    post("/jobs/:id/resume", Controller, :resume_job)
    post("/jobs/:id/reconcile", Controller, :reconcile_job)
    get("/jobs/:id/artifacts", Controller, :job_artifacts)

    get("/artifacts/:id", Controller, :artifact)
    get("/artifacts/:id/content", Controller, :artifact_content)

    get("/openapi.json", Controller, :openapi)
    match(:*, "/*request_path", ErrorController, :not_found)
  end

  scope "/.well-known", GSMLG.AdminWeb.BrowserAPI do
    pipe_through([:api, :browser_bearer_auth])

    get("/api-catalog", Controller, :catalog)
  end

  scope "/mcp" do
    pipe_through(:mcp_admin_api)

    forward("/gao_note", GSMLG.GaoNote.MCP.AdminPlug)
  end

  scope "/api", GSMLG.AdminWeb do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    delete("/sign_out", AuthController, :sign_out)

    post("/blogs", BlogController, :create)
    put("/blogs/:id", BlogController, :update)
    delete("/blogs/:id", BlogController, :delete)
  end

  scope "/api", GSMLG do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    get "/vapid-public-key", WebPushController, :public_key
    post "/subscribe", WebPushController, :subscribe
    post "/send-notification", WebPushController, :send_notification
  end

  if Application.compile_env(:gsmlg_admin_web, :dev_routes) do
    scope "/dev" do
      pipe_through(:browser)

      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  def ensure_session_process_started(conn, _) do
    session_id = get_session(conn, :session_id)

    if Phoenix.SessionProcess.started?(session_id) do
      conn
    else
      user = Guardian.Plug.current_resource(conn)
      Phoenix.SessionProcess.start_session(session_id, args: %{user: user})
      conn
    end
  end
end
