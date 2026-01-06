# Production configuration for Commander E2E Test Framework
import Config

config :gsmlg_commander_test,
  # Use info level in production
  log_level: :info,

  # Standard timeouts
  connect_timeout: 10_000,
  scenario_timeout: 60_000,

  # Both console and JSON reporters
  reporters: [:console, :json]
