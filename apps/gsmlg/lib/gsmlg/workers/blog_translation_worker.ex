defmodule GSMLG.Workers.BlogTranslationWorker do
  @moduledoc """
  Oban worker that translates a blog post into a target locale using the configured provider.

  ## Job Args
  - `"blog_id"` — ID of the blog to translate
  - `"locale"` — Target BCP-47 locale tag (e.g. `"en"`, `"fr"`)
  - `"source_locale"` — Source locale of the blog content

  ## Retry Behaviour
  - `{:snooze, 60}` for rate-limit errors (retries after 60 seconds)
  - `{:error, reason}` for retriable failures (Oban retries with exponential backoff)
  - `{:cancel, reason}` for unrecoverable errors (blog not found)
  - On last attempt failure: marks translation as `"failed"` before returning `{:error, _}`
  """

  use Oban.Worker, queue: :translations, max_attempts: 3

  alias GSMLG.Content
  alias GSMLG.Content.{Blog, BlogTranslation}
  alias GSMLG.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"blog_id" => blog_id, "locale" => locale, "source_locale" => source_locale},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Repo.get(Blog, blog_id) do
      nil ->
        {:cancel, "Blog #{blog_id} not found"}

      blog ->
        translation = get_or_create_translation(blog, locale)
        do_translate(blog, translation, locale, source_locale, attempt, max_attempts)
    end
  end

  defp get_or_create_translation(blog, locale) do
    case Content.get_translation(blog.id, locale) do
      nil ->
        {:ok, t} =
          %BlogTranslation{}
          |> BlogTranslation.pending_changeset(%{blog_id: blog.id, locale: locale})
          |> Repo.insert()

        t

      translation ->
        translation
    end
  end

  defp do_translate(blog, translation, locale, source_locale, attempt, max_attempts) do
    {:ok, translation} = Content.mark_translation_in_progress(translation)

    provider =
      Application.get_env(:gsmlg, :translation_provider, GSMLG.Translation.ClaudeProvider)

    case provider.translate(blog.title, blog.content, source_locale, locale) do
      {:ok, %{title: translated_title, content: translated_content}} ->
        {:ok, completed} =
          Content.complete_translation(translation, translated_title, translated_content)

        if completed.status == "completed" do
          Phoenix.PubSub.broadcast(
            GSMLG.PubSub,
            "blog_translations:#{blog.id}",
            {:translation_updated, blog.id, locale, "completed"}
          )
        end

        {:ok, :translated}

      {:error, :rate_limited} ->
        {:ok, _} = revert_to_pending(translation)
        {:snooze, 60}

      {:error, reason} ->
        if attempt >= max_attempts do
          {:ok, _} = Content.mark_translation_failed(translation)

          Phoenix.PubSub.broadcast(
            GSMLG.PubSub,
            "blog_translations:#{blog.id}",
            {:translation_updated, blog.id, locale, "failed"}
          )
        else
          {:ok, _} = revert_to_pending(translation)
        end

        {:error, reason}
    end
  end

  defp revert_to_pending(%BlogTranslation{} = translation) do
    translation
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update()
  end
end
