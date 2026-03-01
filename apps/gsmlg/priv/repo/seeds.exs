# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     GSMLG.Repo.insert!(%GSMLG.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

users = [
  %{username: "test", email: "test@gsmlg.dev", password: "test"},
  %{username: "josh", email: "josh@gsmlg.dev", password: "Josh2026"}
]

for attrs <- users do
  %GSMLG.Accounts.User{}
  |> GSMLG.Accounts.User.create_changeset(attrs)
  |> GSMLG.Repo.insert!(on_conflict: :nothing, conflict_target: :username)
end
