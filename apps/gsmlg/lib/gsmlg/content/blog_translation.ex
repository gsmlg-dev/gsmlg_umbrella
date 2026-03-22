defmodule GSMLG.Content.BlogTranslation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.Content.Blog

  @valid_statuses ~w[pending in_progress completed failed outdated]

  schema "blog_translations" do
    field :locale, :string
    field :title, :string
    field :content, :string
    field :status, :string, default: "pending"
    field :manually_edited, :boolean, default: false

    belongs_to :blog, Blog

    timestamps()
  end

  def pending_changeset(translation, attrs) do
    translation
    |> cast(attrs, [:blog_id, :locale])
    |> validate_required([:blog_id, :locale])
    |> put_change(:status, "pending")
    |> put_change(:manually_edited, false)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:blog_id, :locale])
  end

  def progress_changeset(translation) do
    change(translation, status: "in_progress")
  end

  def complete_changeset(translation, title, content) do
    change(translation, title: title, content: content, status: "completed")
  end

  def fail_changeset(translation) do
    change(translation, status: "failed")
  end

  def outdated_changeset(translation) do
    change(translation, status: "outdated")
  end

  def admin_edit_changeset(translation, title, content) do
    change(translation,
      title: title,
      content: content,
      status: "completed",
      manually_edited: true
    )
  end
end
