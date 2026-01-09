# In CI (when POSTGRES_HOST is set), exclude config loading tests
# since they test loading from local TOML config files which may
# have different structure in CI
exclude_opts =
  if System.get_env("POSTGRES_HOST") do
    [exclude: [:config_loading]]
  else
    []
  end

ExUnit.start(exclude_opts)
