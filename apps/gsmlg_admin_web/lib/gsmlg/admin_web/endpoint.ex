defmodule GSMLG.AdminWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :gsmlg_admin_web

  @session_options [
    store: :cookie,
    key: "_gsmlg_admin_web_key",
    signing_salt: "PCs9e3vu"
  ]

  @websocket_options [
    connect_info: [
      :peer_data,
      :trace_context_headers,
      :x_headers,
      :uri,
      {:session, @session_options}
    ]
  ]

  socket("/socket", GSMLG.AdminWeb.UserSocket, websocket: @websocket_options)

  socket("/commander-socket", GSMLG.AdminWeb.CommanderSocket,
    websocket: [
      connect_info: [
        :peer_data,
        :uri
      ]
    ],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket,
    websocket: @websocket_options,
    longpoll: @websocket_options
  )

  plug Plug.Static,
    at: "/",
    from: :gsmlg_admin_web,
    gzip: false,
    only: ~w(
      404.html
      assets
      blogs
      blogs.html
      favicon.ico
      games
      games.html
      images
      index.html
      _next
      presentations.html
      tools
      tools.html
      webgl
      robot.txt
      cache_manifest.json
    )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :gsmlg_admin_web
  end

  # plug Phoenix.LiveDashboard.RequestLogger,
  #  param_key: "request_logger",
  #  cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GSMLG.AdminWeb.Router
end
