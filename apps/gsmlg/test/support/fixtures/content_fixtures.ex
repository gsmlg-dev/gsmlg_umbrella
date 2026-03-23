defmodule GSMLG.ContentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GSMLG.Content` context.
  """

  @doc """
  Generate a blog.
  """
  def blog_fixture(attrs \\ %{}) do
    {:ok, blog} =
      attrs
      |> Enum.into(%{
        author: "some author",
        content: "some content",
        date: ~D[2021-09-26],
        slug: "some-slug-#{System.unique_integer([:positive])}",
        title: "some title",
        source_locale: "zh-Hans"
      })
      |> GSMLG.Content.create_blog()

    blog
  end

  def blog_translation_fixture(attrs \\ %{}) do
    blog = attrs[:blog] || blog_fixture()
    locale = attrs[:locale] || "en"

    {:ok, translation} =
      %GSMLG.Content.BlogTranslation{}
      |> GSMLG.Content.BlogTranslation.pending_changeset(%{blog_id: blog.id, locale: locale})
      |> GSMLG.Repo.insert(on_conflict: :nothing, conflict_target: [:blog_id, :locale])

    # If nothing was inserted (conflict), fetch the existing record
    translation =
      if translation.id == nil do
        GSMLG.Repo.get_by!(GSMLG.Content.BlogTranslation, blog_id: blog.id, locale: locale)
      else
        translation
      end

    case attrs[:status] do
      "completed" ->
        {:ok, translation} =
          translation
          |> GSMLG.Content.BlogTranslation.complete_changeset(
            attrs[:title] || "translated title",
            attrs[:content] || "translated content"
          )
          |> GSMLG.Repo.update()

        translation

      _ ->
        translation
    end
  end
end
