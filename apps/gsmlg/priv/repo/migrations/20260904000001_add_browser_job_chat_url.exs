defmodule GSMLG.Repo.Migrations.AddBrowserJobChatURL do
  use Ecto.Migration

  def change do
    alter table(:browser_jobs) do
      add :chat_url, :string
    end
  end
end
