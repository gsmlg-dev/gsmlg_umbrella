defmodule GSMLG.Content.Blog do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Repo
  alias GSMLG.Content.Blog

  schema "blogs" do
    field(:author, :string)
    field(:content, :string)
    field(:date, :date)
    field(:slug, :string)
    field(:title, :string)

    timestamps()
  end

  @doc false
  def changeset(blog, attrs) do
    blog
    |> cast(attrs, [:slug, :title, :date, :author, :content, :id])
    |> validate_required([:slug, :title, :date, :author, :content])
  end

  def count() do
    Repo.aggregate(Blog, :count)
  end
end
