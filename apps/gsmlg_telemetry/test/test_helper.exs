ExUnit.start()

# Only set up Ecto sandbox if GSMLG.Repo is available
if Code.ensure_loaded?(GSMLG.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(GSMLG.Repo, :manual)
end
