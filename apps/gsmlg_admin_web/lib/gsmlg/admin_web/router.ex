defmodule GSMLG.AdminWeb.Router do
  use GSMLG.AdminWeb, :router

  pipeline :maybe_browser_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLG.AdminWeb.Guardian,
      error_handler: GSMLG.AdminWeb.Guardian.WebAuthErrorHandler
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

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # oauth2 authentication, not set yet
  # scope "/auth", GSMLG.AdminWeb do
  #   pipe_through :browser

  #   get("/:provider", AuthController, :request)
  #   get("/:provider/callback", AuthController, :callback)
  # end

  scope "/", GSMLG.AdminWeb do
    pipe_through([:browser, :maybe_browser_auth])

    get("/sign_in", AuthController, :index)
    post("/sign_in", AuthController, :sign_in)

    get("/sign_up", AuthController, :new)
    post("/sign_up", AuthController, :sign_up)
  end

  scope "/", GSMLG.AdminWeb do
    pipe_through([:browser, :maybe_browser_auth, :ensure_authed_access])

    delete("/sign_out", AuthController, :sign_out)

    get("/", PageController, :index)

    get("/node_management", NodeManagementController, :index)
    post("/node_management", NodeManagementController, :update)

    live("/blogs", BlogLive.Index, :index)
    live("/blogs/import", BlogLive.Import, :import)
    live("/blogs/new", BlogLive.Index, :new)
    live("/blogs/settings", BlogLive.Index, :settings)
    live("/blogs/:id", BlogLive.Index, :show)
    live("/blogs/:id/edit", BlogLive.Index, :edit)
    live("/blogs/:id/translations", BlogLive.TranslationLive.Index, :index)

    live("/users", UserLive.Index, :index)
    live("/users/new", UserLive.Index, :new)
    live("/users/:id", UserLive.Index, :show)
    live("/users/:id/edit", UserLive.Index, :edit)
    live("/users/:id/reset_password", UserLive.Index, :reset_password)

    live("/user_tokens", UserTokenLive.Index, :index)
    live("/user_tokens/new", UserTokenLive.Index, :new)
    live("/user_tokens/:id/edit", UserTokenLive.Index, :edit)
    live("/user_tokens/:id", UserTokenLive.Index, :show)

    live("/web_push", WebPushLive.Index, :index)

    live("/command_platform", CommandPlatformLive.Index, :index)
    live("/pty_terminal/:agent_id", PTYTerminalLive, :show)

    # Commander Management Routes
    live("/commander", CommanderLive.DashboardLive, :index)
    live("/commander/list", CommanderLive.ListLive, :index)
    live("/commander/tokens", CommanderLive.TokensLive, :index)
    live("/commander/tokens/new", CommanderLive.TokensLive, :new)
    live("/commander/:id", CommanderLive.ShowLive, :show)
    live("/commander/:id/shell", CommanderLive.ShowLive, :shell)
    live("/commander/:id/:tab", CommanderLive.ShowLive, :show)

    live("/mnesia", MnesiaLive.Index, :index)

    live("/github", GithubLive.Index, :index)

    live("/aws/route53/hosted_zones", Route53Live.Index, :list_zones)
    live("/aws/route53/hosted_zones/:id/records", Route53Live.Index, :list_records)

    live("/aws/dynamo_db", DynamoDBLive.Index, :index)
    live("/aws/dynamo_db/:table/scan", DynamoDBLive.Index, :scan)

    live("/aws/s3/buckets", S3Live.Index, :list_buckets)

    live("/bumblebee/stt", Bumblebee.SttLive.Index, :index)

    # PKI Management Routes
    live("/pki/ca", PKILive.CALive.Index, :index)
    live("/pki/ca/new", PKILive.CALive.Index, :new)
    live("/pki/ca/:ca_id", PKILive.CALive.Show, :show)
    live("/pki/ca/:ca_id/stats", PKILive.CALive.Show, :stats)

    live("/pki/certificates", PKILive.CertificateLive.Index, :index)
    live("/pki/certificates/issue", PKILive.CertificateLive.Index, :issue)
    live("/pki/certificates/:serial", PKILive.CertificateLive.Show, :show)
    live("/pki/certificates/:serial/revoke", PKILive.CertificateLive.Show, :revoke)

    live("/pki/csr", PKILive.CSRLive.Index, :index)
    live("/pki/csr/upload", PKILive.CSRLive.Index, :upload)

    live("/pki/crl/:ca_id", PKILive.CRLLive.Index, :show)

    live("/pki/search", PKILive.SearchLive.Index, :index)
    live("/pki/analytics", PKILive.AnalyticsLive.Index, :index)

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

  scope "/api", GSMLG.AdminWeb do
    pipe_through([:api, :maybe_api_auth])

    post("/sign_in", AuthController, :sign_in)
    post("/sign_up", AuthController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:id", BlogController, :show)
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
