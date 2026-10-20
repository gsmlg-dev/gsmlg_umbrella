defmodule GSMLG.Repo.Migrations.UpdateObanJobsToV14 do
  use Ecto.Migration

  # Styx's initial schema already includes the former Oban v14 changes.
  def up, do: :ok
  def down, do: :ok
end
