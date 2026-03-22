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
    field(:source_locale, :string, default: "zh-Hans")

    timestamps()
  end

  @doc false
  def changeset(blog, attrs) do
    blog
    |> cast(attrs, [:slug, :title, :date, :author, :content, :source_locale, :id])
    |> validate_required([:slug, :title, :date, :author, :content])
  end

  def count() do
    Repo.aggregate(Blog, :count)
  end

  defimpl Jason.Encoder do
    def encode(
          %Blog{id: id, author: author, slug: slug, title: title, date: date, content: content},
          opts
        ) do
      Jason.Encode.map(
        %{id: id, author: author, slug: slug, title: title, date: date, content: content},
        opts
      )
    end
  end
end
