# Development configuration for Commander E2E Test Framework
import Config

config :gsmlg_commander_test,
  # Use debug level for development
  log_level: :debug,

  # More verbose output in dev
  verbose: true,

  # Enable all reporters
  reporters: [:console]
