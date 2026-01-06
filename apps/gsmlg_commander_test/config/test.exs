# Test configuration for Commander E2E Test Framework
import Config

config :gsmlg_commander_test,
  # Use different port for test env to avoid conflicts
  server_port: 14100,

  # Shorter timeouts for faster test feedback
  connect_timeout: 2_000,
  scenario_timeout: 10_000,
  health_check_timeout: 5_000,

  # Minimal output during tests
  verbose: false,
  reporters: [:console]

# Configure logger for test environment
config :logger, level: :warning
