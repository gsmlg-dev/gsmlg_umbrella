# In CI (when POSTGRES_HOST is set), exclude Mnesia tests as they require
# distributed Erlang which isn't configured in CI environment
exclude_opts =
  if System.get_env("POSTGRES_HOST") do
    [exclude: [:mnesia]]
  else
    []
  end

ExUnit.start(exclude_opts)
