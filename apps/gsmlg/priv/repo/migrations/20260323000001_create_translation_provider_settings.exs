defmodule GSMLG.Repo.Migrations.CreateTranslationProviderSettings do
  use Ecto.Migration

  def change do
    create table(:translation_provider_settings) do
      add :provider, :string, null: false, default: "claude"
      add :api_key, :string, null: false, default: ""
      add :model, :string, null: false, default: "claude-haiku-4-5-20251001"
      add :system_prompt, :text

      timestamps()
    end
  end
end
