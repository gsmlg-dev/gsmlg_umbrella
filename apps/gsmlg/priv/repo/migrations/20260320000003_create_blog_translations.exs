defmodule GSMLG.Repo.Migrations.CreateBlogTranslations do
  use Ecto.Migration

  def change do
    create table(:blog_translations) do
      add :blog_id, references(:blogs, on_delete: :delete_all), null: false
      add :locale, :string, null: false
      add :title, :string
      add :content, :text
      add :status, :string, null: false, default: "pending"
      add :manually_edited, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:blog_translations, [:blog_id, :locale])
    create index(:blog_translations, [:locale])
    create index(:blog_translations, [:status])
  end
end
