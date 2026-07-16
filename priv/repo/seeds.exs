# Umbrella-root seed entrypoint for `mix ecto.setup`.
# The GSMLG app owns the actual Repo seed data.
Code.require_file("apps/gsmlg/priv/repo/seeds.exs")
