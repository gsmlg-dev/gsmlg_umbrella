import Config

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end

if config_env() == :prod do
  config :phoenix_react_server, Phoenix.React.Runtime.Bun,
    cmd: System.get_env("MIX_BUN_PATH", System.find_executable("bun")),
    server_js: System.get_env("BUN_SERVER_JS"),
    port: String.to_integer(System.get_env("BUN_PORT", "5252")),
    env: :prod
end
