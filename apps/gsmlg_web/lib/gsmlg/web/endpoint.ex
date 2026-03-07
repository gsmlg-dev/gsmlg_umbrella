defmodule GSMLG.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :gsmlg_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_gsmlg_web_key",
    signing_salt: "PCs9e3vu"
  ]

  @websocket_options [
    connect_info: [
      :peer_data,
      :trace_context_headers,
      :x_headers,
      :user_agent,
      :uri,
      {:session, @session_options}
    ]
  ]

  socket "/socket", GSMLG.Web.UserSocket, websocket: @websocket_options
  socket "/live", Phoenix.LiveView.Socket,
    websocket: @websocket_options,
    longpoll: @websocket_options

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :gsmlg_web,
    gzip: false,
    only: ~w(
      assets
      favicon.ico
      images
      robots.txt
      cache_manifest.json
    )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :gsmlg_web
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
  plug GSMLG.Web.Router
end
