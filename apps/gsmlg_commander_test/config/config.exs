# Configuration for Commander E2E Test Framework
import Config

config :gsmlg_commander_test,
  # Server settings
  server_port: 14000,

  # Timeouts (faster for testing)
  connect_timeout: 5_000,
  scenario_timeout: 30_000,
  health_check_timeout: 10_000,

  # Test configuration for server (fast timeouts for testing)
  server_config: [
    idle_timeout: :timer.seconds(30),
    reconnect_grace_period: :timer.seconds(10),
    heartbeat_interval: :timer.seconds(5)
  ],

  # Reporters
  reporters: [:console],

  # Stress test limits
  stress: [
    max_agents: 100,
    max_duration: :timer.minutes(5)
  ]

# Import environment specific config
import_config "#{config_env()}.exs"
