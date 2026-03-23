defmodule GSMLG.Workers.BlogTranslationWorkerTest do
  use GSMLG.DataCase
  use Oban.Testing, repo: GSMLG.Repo

  import Mox
  import GSMLG.ContentFixtures

  alias GSMLG.Content
  alias GSMLG.Workers.BlogTranslationWorker

  # Mox requires the mock to be verified after each test
  setup :verify_on_exit!

  describe "perform/1" do
    test "successful translation calls complete_translation" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      translation = blog_translation_fixture(%{blog: blog, locale: "en"})

      GSMLG.Translation.MockProvider
      |> expect(:translate, fn _title, _content, _source, _target ->
        {:ok, %{title: "Translated Title", content: "Translated Content"}}
      end)

      job = %Oban.Job{
        args: %{"blog_id" => blog.id, "locale" => "en", "source_locale" => "zh-Hans"},
        attempt: 1,
        max_attempts: 3
      }

      assert {:ok, _} = BlogTranslationWorker.perform(job)

      updated = Content.get_translation(blog.id, "en")
      assert updated.status == "completed"
      assert updated.title == "Translated Title"
      assert updated.content == "Translated Content"
    end

    test "returns {:cancel, _} when blog not found" do
      job = %Oban.Job{
        args: %{"blog_id" => 999_999, "locale" => "en", "source_locale" => "zh-Hans"},
        attempt: 1,
        max_attempts: 3
      }

      assert {:cancel, _reason} = BlogTranslationWorker.perform(job)
    end

    test "marks translation failed on last attempt when provider errors" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      _translation = blog_translation_fixture(%{blog: blog, locale: "en"})

      GSMLG.Translation.MockProvider
      |> expect(:translate, fn _title, _content, _source, _target ->
        {:error, :api_error}
      end)

      job = %Oban.Job{
        args: %{"blog_id" => blog.id, "locale" => "en", "source_locale" => "zh-Hans"},
        attempt: 3,
        max_attempts: 3
      }

      assert {:error, _} = BlogTranslationWorker.perform(job)

      updated = Content.get_translation(blog.id, "en")
      assert updated.status == "failed"
    end

    test "returns {:snooze, _} for rate-limit errors" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      _translation = blog_translation_fixture(%{blog: blog, locale: "en"})

      GSMLG.Translation.MockProvider
      |> expect(:translate, fn _title, _content, _source, _target ->
        {:error, :rate_limited}
      end)

      job = %Oban.Job{
        args: %{"blog_id" => blog.id, "locale" => "en", "source_locale" => "zh-Hans"},
        attempt: 1,
        max_attempts: 3
      }

      assert {:snooze, snooze_seconds} = BlogTranslationWorker.perform(job)
      assert snooze_seconds > 0
    end

    test "returns {:error, _} (retry) for non-final attempt failures" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      _translation = blog_translation_fixture(%{blog: blog, locale: "en"})

      GSMLG.Translation.MockProvider
      |> expect(:translate, fn _title, _content, _source, _target ->
        {:error, :api_error}
      end)

      job = %Oban.Job{
        args: %{"blog_id" => blog.id, "locale" => "en", "source_locale" => "zh-Hans"},
        attempt: 1,
        max_attempts: 3
      }

      assert {:error, _} = BlogTranslationWorker.perform(job)
      # Status should NOT be failed yet (not the last attempt)
      updated = Content.get_translation(blog.id, "en")
      assert updated.status in ["pending", "in_progress"]
    end
  end
end
