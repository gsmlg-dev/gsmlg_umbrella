defmodule GSMLG.Content do
  @moduledoc """
  The Content context.
  """

  import Ecto.Query, warn: false
  alias GSMLG.Repo

  alias GSMLG.Content.Blog
  alias GSMLG.Content.BlogTranslation
  alias GSMLG.Content.TranslationProviderSetting

  defp supported_locales, do: GSMLG.Locale.supported()

  @doc """
  Returns the count of blogs.

  ## Examples

      iex> count_blogs()
      [%Blog{}, ...]

  """
  def count_blogs do
    Repo.aggregate(Blog, :count)
  end

  def count_blogs(args) do
    query =
      from b in Blog,
        where: ^args

    Repo.aggregate(query, :count)
  end

  def last_updated_at() do
    blog = GSMLG.Repo.one(from GSMLG.Content.Blog, limit: 1, order_by: [desc: :updated_at])
    blog && blog.updated_at
  end

  @doc """
  Returns the list of blogs.

  ## Examples

      iex> list_blogs()
      [%Blog{}, ...]

  """
  def list_blogs do
    query =
      from b in Blog,
        order_by: [desc: :id]

    Repo.all(query)
  end

  def list_blogs(args) do
    query =
      from b in Blog,
        where: ^args,
        order_by: [desc: :id]

    Repo.all(query)
  end

  def list_blogs_limit(args, limit, offset, order_by) do
    query =
      cond do
        Enum.count(args) == 0 and Enum.count(order_by) == 0 ->
          from b in Blog, limit: ^limit, offset: ^offset, order_by: [desc: :id]

        Enum.count(args) == 0 ->
          from b in Blog, limit: ^limit, offset: ^offset, order_by: ^order_by

        Enum.count(order_by) == 0 and Enum.count(args) > 0 ->
          from b in Blog, where: ^args, limit: ^limit, offset: ^offset, order_by: [desc: :id]

        Enum.count(args) > 0 ->
          from b in Blog, where: ^args, limit: ^limit, offset: ^offset, order_by: ^order_by
      end

    Repo.all(query)
  end

  @doc """
  Gets a single blog.

  Raises `Ecto.NoResultsError` if the Blog does not exist.

  ## Examples

      iex> get_blog!(123)
      %Blog{}

      iex> get_blog!(456)
      ** (Ecto.NoResultsError)

  """
  def get_blog!(id), do: Repo.get!(Blog, id)

  def get_blog_by_slug(slug) do
    query = from b in Blog, where: [slug: ^slug]
    Repo.one(query)
  end

  @doc """
  Creates a blog.

  ## Examples

      iex> create_blog(%{field: value})
      {:ok, %Blog{}}

      iex> create_blog(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_blog(attrs \\ %{}) do
    changeset = Blog.changeset(%Blog{}, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:blog, changeset)
    |> Ecto.Multi.run(:jobs, fn _repo, %{blog: blog} ->
      supported = supported_locales()
      locales = Enum.reject(supported, &(&1 == blog.source_locale))

      jobs =
        Enum.map(locales, fn locale ->
          GSMLG.Workers.BlogTranslationWorker.new(%{
            "blog_id" => blog.id,
            "locale" => locale,
            "source_locale" => blog.source_locale
          })
        end)

      inserted = Oban.insert_all(jobs)
      {:ok, length(inserted)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{blog: blog}} -> {:ok, blog}
      {:error, :blog, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Updates a blog.

  ## Examples

      iex> update_blog(blog, %{field: new_value})
      {:ok, %Blog{}}

      iex> update_blog(blog, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_blog(%Blog{} = blog, attrs) do
    changeset = Blog.changeset(blog, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:blog, changeset)
    |> Ecto.Multi.run(:outdated, fn _repo, %{blog: updated_blog} ->
      # Mark non-manually_edited translations as outdated
      {count, _} =
        from(t in BlogTranslation,
          where: t.blog_id == ^updated_blog.id and t.manually_edited == false,
          where: t.status in ["pending", "in_progress", "completed"]
        )
        |> Repo.update_all(set: [status: "outdated"])

      {:ok, count}
    end)
    |> Ecto.Multi.run(:cleanup_source_locale_translation, fn _repo, %{blog: updated_blog} ->
      # If source_locale was corrected, delete any translation record whose locale now
      # matches the new source_locale — it is the source content, not a translation.
      from(t in BlogTranslation,
        where: t.blog_id == ^updated_blog.id and t.locale == ^updated_blog.source_locale
      )
      |> Repo.delete_all()

      {:ok, :done}
    end)
    |> Ecto.Multi.run(:jobs, fn _repo, %{blog: updated_blog} ->
      # Re-enqueue jobs for outdated (non-manually_edited) translations,
      # excluding any translation whose locale matches the new source_locale.
      outdated_translations =
        from(t in BlogTranslation,
          where: t.blog_id == ^updated_blog.id and t.status == "outdated",
          where: t.manually_edited == false,
          where: t.locale != ^updated_blog.source_locale
        )
        |> Repo.all()

      jobs =
        Enum.map(outdated_translations, fn t ->
          GSMLG.Workers.BlogTranslationWorker.new(%{
            "blog_id" => updated_blog.id,
            "locale" => t.locale,
            "source_locale" => updated_blog.source_locale
          })
        end)

      if jobs != [], do: Oban.insert_all(jobs)
      {:ok, length(jobs)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{blog: blog}} -> {:ok, blog}
      {:error, :blog, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Deletes a blog.

  ## Examples

      iex> delete_blog(blog)
      {:ok, %Blog{}}

      iex> delete_blog(blog)
      {:error, %Ecto.Changeset{}}

  """
  def delete_blog(%Blog{} = blog) do
    Repo.delete(blog)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking blog changes.

  ## Examples

      iex> change_blog(blog)
      %Ecto.Changeset{data: %Blog{}}

  """
  def change_blog(%Blog{} = blog, attrs \\ %{}) do
    Blog.changeset(blog, attrs)
  end

  # ---------------------------------------------------------------------------
  # Translation functions
  # ---------------------------------------------------------------------------

  def get_translation(blog_id, locale) do
    Repo.get_by(BlogTranslation, blog_id: blog_id, locale: locale)
  end

  def get_translation!(blog_id, locale) do
    Repo.get_by!(BlogTranslation, blog_id: blog_id, locale: locale)
  end

  def list_translations(blog_id) do
    Repo.all(from t in BlogTranslation, where: t.blog_id == ^blog_id, order_by: t.locale)
  end

  def create_pending_translations(blog, locales) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    records =
      locales
      |> Enum.reject(fn locale -> locale == blog.source_locale end)
      |> Enum.map(fn locale ->
        %{
          blog_id: blog.id,
          locale: locale,
          status: "pending",
          manually_edited: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(BlogTranslation, records, on_conflict: :nothing)
    {:ok, records}
  end

  def mark_translation_in_progress(%BlogTranslation{} = translation) do
    translation
    |> BlogTranslation.progress_changeset()
    |> Repo.update()
  end

  def complete_translation(%BlogTranslation{} = translation, title, content) do
    # Only complete if still in_progress — guards against a blog update marking
    # this translation outdated while the worker was running.
    {count, _} =
      from(t in BlogTranslation,
        where: t.id == ^translation.id and t.status == "in_progress"
      )
      |> Repo.update_all(
        set: [title: title, content: content, status: "completed", updated_at: DateTime.utc_now()]
      )

    if count > 0 do
      {:ok, %{translation | title: title, content: content, status: "completed"}}
    else
      {:ok, translation}
    end
  end

  def mark_translation_failed(%BlogTranslation{} = translation) do
    translation
    |> BlogTranslation.fail_changeset()
    |> Repo.update()
  end

  def admin_edit_translation(%BlogTranslation{} = translation, title, content) do
    translation
    |> BlogTranslation.admin_edit_changeset(title, content)
    |> Repo.update()
  end

  def retranslate(%BlogTranslation{} = translation) do
    translation
    |> Ecto.Changeset.change(status: "pending", manually_edited: false, title: nil, content: nil)
    |> Repo.update()
  end

  # ── Translation Provider Settings ────────────────────────────────────────

  @doc "Returns the current translation provider setting, or a default struct if none saved."
  def get_translation_provider_setting do
    case Repo.one(from s in TranslationProviderSetting, limit: 1, order_by: [asc: :id]) do
      nil -> %TranslationProviderSetting{}
      setting -> setting
    end
  end

  @doc "Upserts the translation provider setting (singleton row)."
  def upsert_translation_provider_setting(attrs) do
    setting = get_translation_provider_setting()

    setting
    |> TranslationProviderSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Returns a changeset for the translation provider setting form."
  def change_translation_provider_setting(%TranslationProviderSetting{} = setting, attrs \\ %{}) do
    TranslationProviderSetting.changeset(setting, attrs)
  end

  def batch_pending_translations do
    supported_locales = GSMLG.Locale.supported()

    existing_needing_work =
      from(t in BlogTranslation,
        where: t.status in ["failed", "outdated"],
        select: {t.blog_id, t.locale}
      )
      |> Repo.all()

    all_existing_pairs =
      from(t in BlogTranslation, select: {t.blog_id, t.locale})
      |> Repo.all()
      |> MapSet.new()

    blogs = Repo.all(from b in Blog, select: {b.id, b.source_locale})

    missing =
      for {blog_id, source_locale} <- blogs,
          locale <- supported_locales,
          locale != source_locale,
          not MapSet.member?(all_existing_pairs, {blog_id, locale}),
          do: {blog_id, locale}

    (existing_needing_work ++ missing) |> Enum.uniq()
  end
end
