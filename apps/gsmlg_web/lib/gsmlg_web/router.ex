defmodule GSMLGWeb.Router do
  use GSMLGWeb, :router

  pipeline :maybe_browser_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLGWeb.Guardian,
      error_handler: GSMLGWeb.Guardian.WebAuthErrorHandler
    )

    plug(Guardian.Plug.VerifySession, halt: false)
    plug(Guardian.Plug.LoadResource, allow_blank: true)
  end

  pipeline :maybe_api_auth do
    plug(Guardian.Plug.Pipeline,
      module: GSMLGWeb.Guardian,
      error_handler: GSMLGWeb.Guardian.ApiAuthErrorHandler
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
    plug(Phoenix.SessionProcess.SessionId)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {GSMLGWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:put_sw_header)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/auth", GSMLGWeb do
    pipe_through :browser

    get("/:provider", AuthController, :request)
    get("/:provider/callback", AuthController, :callback)
  end

  scope "/", GSMLGWeb do
    pipe_through([:browser, :maybe_browser_auth])

    get("/", PageController, :index)

    get("/sign_in", SignController, :index)
    # post("/sign_in", SignController, :sign_in)

    get("/sign_up", SignController, :new)
    # post("/sign_up", SignController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:slug", BlogController, :show)

    get("/toolbox", ToolboxController, :index)
    get("/toolbox/geoip2", ToolboxController, :geoip2)
    post("/toolbox/geoip2", ToolboxController, :geoip2_find)
    get("/toolbox/whois", ToolboxController, :whois)
    post("/toolbox/whois", ToolboxController, :whois_find)
    get("/toolbox/svg2react", ToolboxController, :svg2react)
    post("/toolbox/svg2react", ToolboxController, :svg2react_convert)
    get("/toolbox/svg_autocrop", ToolboxController, :svg_autocrop)
    post("/toolbox/svg_autocrop", ToolboxController, :svg_autocrop_convert)
    get("/toolbox/mac_manufacturer", ToolboxController, :mac_manufacturer)
    post("/toolbox/mac_manufacturer", ToolboxController, :mac_manufacturer_lookup)
    get("/toolbox/ip_to_geomap", ToolboxController, :ip_to_geomap)
    get("/toolbox/screensaver", ToolboxController, :screensaver)
  end

  scope "/api", GSMLGWeb do
    pipe_through([:api, :maybe_api_auth])

    post("/sign_in", AuthController, :sign_in)
    post("/sign_up", AuthController, :sign_up)

    get("/blogs", BlogController, :index)
    get("/blogs/:id", BlogController, :show)

    get("/toolbox/ip_to_geomap", ToolboxController, :ip_to_geomap_post)
  end

  scope "/api", GSMLG do
    pipe_through([:api, :maybe_api_auth])

    get "/vapid-public-key", WebPushController, :public_key
    post "/subscribe", WebPushController, :subscribe
  end

  scope "/api", GSMLG do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    post "/send-notification", WebPushController, :send_notification
  end

  # Other scopes may use custom stacks.
  scope "/api", GSMLGWeb do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    delete("/sign_out", AuthController, :sign_out)

    post("/blogs", BlogController, :create)
    put("/blogs/:id", BlogController, :update)
    delete("/blogs/:id", BlogController, :delete)
  end

  forward(
    "/graphiql",
    Absinthe.Plug.GraphiQL,
    schema: GSMLGWeb.Schema,
    socket: GSMLGWeb.UserSocket
  )

  forward("/graphql", Absinthe.Plug, schema: GSMLGWeb.Schema)

  # fallback not_found
  scope "/", GSMLGWeb do
    pipe_through(:browser)

    get("/*request_path", PageController, :not_found)
  end

  # Private function to set the header for serviceworker
  defp put_sw_header(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("Link", ~s[</assets/sw.js>; rel="serviceworker"; scope="/"])
  end
end
