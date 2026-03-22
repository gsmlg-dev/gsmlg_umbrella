defmodule Mix.Tasks.Blog.TranslatePendingTest do
  use GSMLG.DataCase
  use Oban.Testing, repo: GSMLG.Repo

  alias Mix.Tasks.Blog.TranslatePending
  alias GSMLG.Content.Blog
  alias GSMLG.Content.BlogTranslation

  # Insert a blog record directly (bypassing create_blog's auto-job enqueuing)
  defp insert_blog(attrs \\ %{}) do
    defaults = %{
      author: "author",
      content: "content",
      date: ~D[2021-09-26],
      slug: "slug-#{System.unique_integer([:positive])}",
      title: "title",
      source_locale: "zh-Hans"
    }

    {:ok, blog} =
      %Blog{}
      |> Blog.changeset(Map.merge(defaults, attrs))
      |> GSMLG.Repo.insert()

    blog
  end

  # Insert a translation record directly with a given status
  defp insert_translation(blog, locale, status \\ "pending") do
    {:ok, translation} =
      %BlogTranslation{}
      |> BlogTranslation.pending_changeset(%{blog_id: blog.id, locale: locale})
      |> GSMLG.Repo.insert(on_conflict: :nothing, conflict_target: [:blog_id, :locale])

    translation =
      if translation.id == nil do
        GSMLG.Repo.get_by!(BlogTranslation, blog_id: blog.id, locale: locale)
      else
        translation
      end

    case status do
      "completed" ->
        {:ok, t} =
          translation
          |> BlogTranslation.complete_changeset("translated title", "translated content")
          |> GSMLG.Repo.update()

        t

      "in_progress" ->
        {:ok, t} = GSMLG.Content.mark_translation_in_progress(translation)
        t

      _ ->
        translation
    end
  end

  describe "run/1 dry-run (no flags)" do
    test "calls batch_pending_translations and prints planned jobs without enqueueing" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "pending")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          TranslatePending.run([])
        end)

      assert output =~ "Will enqueue:"
      assert output =~ "blog_id=#{blog.id}"
      assert output =~ "locale=en"

      # No jobs should have been enqueued in dry-run
      refute_enqueued(worker: GSMLG.Workers.BlogTranslationWorker)
    end

    test "prints N jobs planned summary" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "pending")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          TranslatePending.run([])
        end)

      assert output =~ "jobs planned"
    end
  end

  describe "run/1 with --confirm" do
    test "inserts Oban jobs for all pending translations" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "pending")

      Oban.Testing.with_testing_mode(:manual, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          TranslatePending.run(["--confirm"])
        end)

        assert_enqueued(
          worker: GSMLG.Workers.BlogTranslationWorker,
          args: %{"blog_id" => blog.id, "locale" => "en"}
        )
      end)
    end

    test "prints N jobs enqueued summary" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "pending")

      output =
        Oban.Testing.with_testing_mode(:manual, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            TranslatePending.run(["--confirm"])
          end)
        end)

      assert output =~ "jobs enqueued"
    end
  end

  describe "skip completed/in_progress" do
    test "does not include completed translations in batch_pending result" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "completed")

      pending = GSMLG.Content.batch_pending_translations()

      refute Enum.any?(pending, fn {bid, loc} -> bid == blog.id and loc == "en" end)
    end

    test "does not include in_progress translations in batch_pending result" do
      blog = insert_blog(%{source_locale: "zh-Hans"})
      insert_translation(blog, "en", "in_progress")

      pending = GSMLG.Content.batch_pending_translations()

      refute Enum.any?(pending, fn {bid, loc} -> bid == blog.id and loc == "en" end)
    end

    test "no jobs enqueued for blog with only completed translations" do
      blog = insert_blog(%{source_locale: "zh-Hans"})

      # Insert completed translations for all supported locales except source
      supported = GSMLG.Locale.supported()

      Enum.each(supported, fn locale ->
        if locale != blog.source_locale do
          insert_translation(blog, locale, "completed")
        end
      end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          TranslatePending.run(["--confirm"])
        end)

        # No jobs for this blog should be enqueued
        Enum.each(supported, fn locale ->
          if locale != blog.source_locale do
            refute_enqueued(
              worker: GSMLG.Workers.BlogTranslationWorker,
              args: %{"blog_id" => blog.id, "locale" => locale}
            )
          end
        end)
      end)
    end
  end
end
