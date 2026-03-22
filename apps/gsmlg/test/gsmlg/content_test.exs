defmodule GSMLG.ContentTest do
  use GSMLG.DataCase
  use Oban.Testing, repo: GSMLG.Repo

  alias GSMLG.Content

  describe "blogs" do
    alias GSMLG.Content.Blog

    import GSMLG.ContentFixtures

    @invalid_attrs %{author: nil, content: nil, date: nil, slug: nil, title: nil}

    setup do
      GSMLG.Repo.delete_all(GSMLG.Content.Blog)
      :ok
    end

    test "list_blogs/0 returns all blogs" do
      blog = blog_fixture()
      assert Content.list_blogs() == [blog]
    end

    test "get_blog!/1 returns the blog with given id" do
      blog = blog_fixture()
      assert Content.get_blog!(blog.id) == blog
    end

    test "create_blog/1 with valid data creates a blog" do
      valid_attrs = %{
        author: "some author",
        content: "some content",
        date: ~D[2021-09-26],
        slug: "some slug",
        title: "some title"
      }

      assert {:ok, %Blog{} = blog} = Content.create_blog(valid_attrs)
      assert blog.author == "some author"
      assert blog.content == "some content"
      assert blog.date == ~D[2021-09-26]
      assert blog.slug == "some slug"
      assert blog.title == "some title"
    end

    test "create_blog/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Content.create_blog(@invalid_attrs)
    end

    test "update_blog/2 with valid data updates the blog" do
      blog = blog_fixture()

      update_attrs = %{
        author: "some updated author",
        content: "some updated content",
        date: ~D[2021-09-27],
        slug: "some updated slug",
        title: "some updated title"
      }

      assert {:ok, %Blog{} = blog} = Content.update_blog(blog, update_attrs)
      assert blog.author == "some updated author"
      assert blog.content == "some updated content"
      assert blog.date == ~D[2021-09-27]
      assert blog.slug == "some updated slug"
      assert blog.title == "some updated title"
    end

    test "update_blog/2 with invalid data returns error changeset" do
      blog = blog_fixture()
      assert {:error, %Ecto.Changeset{}} = Content.update_blog(blog, @invalid_attrs)
      assert blog == Content.get_blog!(blog.id)
    end

    test "delete_blog/1 deletes the blog" do
      blog = blog_fixture()
      assert {:ok, %Blog{}} = Content.delete_blog(blog)
      assert_raise Ecto.NoResultsError, fn -> Content.get_blog!(blog.id) end
    end

    test "change_blog/1 returns a blog changeset" do
      blog = blog_fixture()
      assert %Ecto.Changeset{} = Content.change_blog(blog)
    end
  end

  describe "blog translation job enqueueing" do
    import GSMLG.ContentFixtures

    setup do
      GSMLG.Repo.delete_all(GSMLG.Content.Blog)
      :ok
    end

    test "create_blog/1 creates translation records for each non-source supported locale" do
      # In Oban inline testing mode, jobs run immediately on insert.
      # We verify the outcome: translation records exist for all non-source locales.
      supported = GSMLG.Locale.supported()

      attrs = %{
        author: "author",
        content: "content",
        date: ~D[2021-09-26],
        slug: "unique-slug-#{System.unique_integer([:positive])}",
        title: "title",
        source_locale: "zh-Hans"
      }

      assert {:ok, blog} = Content.create_blog(attrs)

      non_source_locales = Enum.reject(supported, &(&1 == "zh-Hans"))

      Enum.each(non_source_locales, fn locale ->
        assert Content.get_translation(blog.id, locale) != nil,
               "Expected translation record for locale #{locale}"
      end)
    end

    test "update_blog/2 re-processes non-manually_edited translations when blog content changes" do
      # In inline mode, jobs run immediately. Verify the translation was updated.
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      _translation = blog_translation_fixture(%{blog: blog, locale: "en"})

      # Override stub for the re-translation call
      Mox.expect(GSMLG.Translation.MockProvider, :translate, fn _title, _content, _src, _tgt ->
        {:ok, %{title: "Re-translated Title", content: "Re-translated Content"}}
      end)

      assert {:ok, _updated_blog} = Content.update_blog(blog, %{title: "New Title"})

      updated_translation = Content.get_translation(blog.id, "en")
      assert updated_translation.title == "Re-translated Title"
    end

    test "update_blog/2 does NOT re-process manually_edited translations" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      translation = blog_translation_fixture(%{blog: blog, locale: "en", status: "completed"})

      {:ok, translation} =
        translation
        |> GSMLG.Content.BlogTranslation.admin_edit_changeset("Manual Title", "Manual Content")
        |> GSMLG.Repo.update()

      assert translation.manually_edited == true

      assert {:ok, _updated_blog} = Content.update_blog(blog, %{title: "New Title"})

      updated_translation = Content.get_translation(blog.id, "en")
      assert updated_translation.manually_edited == true
      assert updated_translation.title == "Manual Title"
    end
  end
end
