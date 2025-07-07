defmodule GSMLGAdminWeb.Router do
  use GSMLGAdminWeb, :router

  pipeline :maybe_browser_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLGAdminWeb.Guardian,
      error_handler: GSMLGAdminWeb.Guardian.WebAuthErrorHandler
    )

    plug(Guardian.Plug.VerifySession, halt: false)
    plug(Guardian.Plug.LoadResource, allow_blank: true)
  end

  pipeline :maybe_api_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLGAdminWeb.Guardian,
      error_handler: GSMLGAdminWeb.Guardian.ApiAuthErrorHandler
    )

    plug(Guardian.Plug.VerifyHeader, halt: false)
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
    plug(:put_root_layout, {GSMLGAdminWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # oauth2 authentication, not set yet
  # scope "/auth", GSMLGWeb do
  #   pipe_through :browser

  #   get("/:provider", AuthController, :request)
  #   get("/:provider/callback", AuthController, :callback)
  # end

  scope "/", GSMLGAdminWeb do
    pipe_through([:browser, :maybe_browser_auth])

    get("/sign_in", AuthController, :index)
    post("/sign_in", AuthController, :sign_in)

    get("/sign_up", AuthController, :new)
    post("/sign_up", AuthController, :sign_up)
  end

  scope "/", GSMLGAdminWeb do
    pipe_through([:browser, :maybe_browser_auth, :ensure_authed_access])

    delete("/sign_out", AuthController, :sign_out)

    get("/", PageController, :index)

    get("/node_management", NodeManagementController, :index)
    post("/node_management", NodeManagementController, :update)

    live("/blogs", BlogLive.Index, :index)
    live("/blogs/import", BlogLive.Import, :import)
    live("/blogs/new", BlogLive.Index, :new)
    live("/blogs/:id", BlogLive.Index, :show)
    live("/blogs/:id/edit", BlogLive.Index, :edit)

    live("/users", UserLive.Index, :index)
    live("/users/new", UserLive.Index, :new)
    live("/users/:id", UserLive.Index, :show)
    live("/users/:id/edit", UserLive.Index, :edit)

    live("/user_tokens", UserTokenLive.Index, :index)
    live("/user_tokens/new", UserTokenLive.Index, :new)
    live("/user_tokens/:id/edit", UserTokenLive.Index, :edit)
    live("/user_tokens/:id", UserTokenLive.Index, :show)

    live("/web_push", WebPushLive.Index, :index)

    live("/command_platform", CommandPlatformLive.Index, :index)

    live("/mnesia", MnesiaLive.Index, :index)

    live("/github", GithubLive.Index, :index)

    live("/aws/route53/hosted_zones", Route53Live.Index, :list_zones)
    live("/aws/route53/hosted_zones/:id/records", Route53Live.Index, :list_records)

    live("/aws/dynamo_db", DynamoDBLive.Index, :index)
    live("/aws/dynamo_db/:table/scan", DynamoDBLive.Index, :scan)

    live("/aws/s3/buckets", S3Live.Index, :list_buckets)

    live("/ai/stt", AI.SttLive.Index, :index)

    import Phoenix.LiveDashboard.Router

    live_dashboard("/live_dashboard", metrics: GSMLGAdminWeb.Telemetry)
  end

  scope "/api", GSMLGAdminWeb do
    pipe_through([:api, :maybe_api_auth])

    post("/sign_in", AuthController, :sign_in)
    post("/sign_up", AuthController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:id", BlogController, :show)
  end

  scope "/api", GSMLGAdminWeb do
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

  forward(
    "/graphiql",
    Absinthe.Plug.GraphiQL,
    schema: GSMLGAdminWeb.Schema,
    socket: GSMLGAdminWeb.UserSocket
  )

  forward("/graphql", Absinthe.Plug, schema: GSMLGAdminWeb.Schema)

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
      Phoenix.SessionProcess.start(session_id, GSMLG.SessionProcess, %{user: user})
      conn
    end
  end
end
