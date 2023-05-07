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
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {GSMLGAdminWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

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
    live("/blogs/new", BlogLive.Modify, :new)
    live("/blogs/:id", BlogLive.Show, :show)
    live("/blogs/:id/edit", BlogLive.Modify, :edit)

    live("/users", UserLive.Index, :index)
    live("/users/new", UserLive.Modify, :new)
    live("/users/:id", UserLive.Show, :show)
    live("/users/:id/edit", UserLive.Modify, :edit)

    live("/user_tokens", UserTokenLive.Index, :index)
    live("/user_tokens/new", UserTokenLive.Modify, :new)
    live("/user_tokens/:id/edit", UserTokenLive.Modify, :edit)
    live("/user_tokens/:id", UserTokenLive.Show, :show)

    live("/command_platform", CommandPlatformLive.Index, :index)
    live("/mnesia", MnesiaLive.Index, :index)

    # if Mix.env() in [:prod] do
    #   import Phoenix.LiveDashboard.Router

    #   live_dashboard("/dashboard", metrics: GSMLGAdminWeb.Telemetry)
    # end
  end

  scope "/api", GSMLGAdminWeb do
    pipe_through([:api, :maybe_api_auth])

    post("/sign_in", AuthController, :sign_in)
    post("/sign_up", AuthController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:id", BlogController, :show)
  end

  # Other scopes may use custom stacks.
  scope "/api", GSMLGAdminWeb do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    delete("/sign_out", AuthController, :sign_out)

    post("/blogs", BlogController, :create)
    put("/blogs/:id", BlogController, :update)
    delete("/blogs/:id", BlogController, :delete)
  end

  forward(
    "/graphiql",
    Absinthe.Plug.GraphiQL,
    schema: GSMLGAdminWeb.Schema,
    socket: GSMLGAdminWeb.UserSocket
  )

  forward("/graphql", Absinthe.Plug, schema: GSMLGAdminWeb.Schema)

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:gsmlg_admin_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    # import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      # live_dashboard("/dashboard", metrics: PhxNextWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
