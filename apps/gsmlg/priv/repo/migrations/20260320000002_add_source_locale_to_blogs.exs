defmodule GSMLG.Repo.Migrations.AddSourceLocaleToBlogs do
  use Ecto.Migration

  def change do
    alter table(:blogs) do
      add :source_locale, :string, null: false, default: "zh-Hans"
    end
  end
end
