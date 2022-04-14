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

%GSMLG.Accounts.User{} |> GSMLG.Accounts.User.create_changeset(%{
  "username": "test",
  "email": "test@gsmlg.dev",
  "password": "test",
}) |> GSMLG.Repo.insert!()
