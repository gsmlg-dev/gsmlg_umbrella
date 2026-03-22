defmodule Mix.Tasks.Blog.TranslatePending do
  @moduledoc """
  Enqueues Oban translation jobs for all blogs with pending, failed, or outdated
  translations, as well as any missing translation pairs.

  By default this is a dry-run — no jobs are inserted into the database.

  ## Usage

      mix blog.translate_pending
      mix blog.translate_pending --confirm

  ## Options

    * `--confirm` — actually insert Oban jobs
    * `--dry-run` — explicit dry-run (default behaviour, no DB writes)

  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  @shortdoc "Enqueue translation jobs for all pending blog translations"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [confirm: :boolean, dry_run: :boolean])

    confirm? = Keyword.get(opts, :confirm, false)

    pending = GSMLG.Content.batch_pending_translations()

    Enum.each(pending, fn {blog_id, locale} ->
      IO.puts("Will enqueue: blog_id=#{blog_id} locale=#{locale}")
    end)

    count = length(pending)

    if confirm? do
      # Build a map of blog_id -> source_locale to include in job args
      blog_ids = pending |> Enum.map(fn {blog_id, _} -> blog_id end) |> Enum.uniq()

      source_locale_map =
        GSMLG.Repo.all(
          from b in GSMLG.Content.Blog,
            where: b.id in ^blog_ids,
            select: {b.id, b.source_locale}
        )
        |> Map.new()

      jobs =
        Enum.map(pending, fn {blog_id, locale} ->
          source_locale = Map.fetch!(source_locale_map, blog_id)

          GSMLG.Workers.BlogTranslationWorker.new(%{
            "blog_id" => blog_id,
            "locale" => locale,
            "source_locale" => source_locale
          })
        end)

      Oban.insert_all(jobs)

      IO.puts("#{count} jobs enqueued")
    else
      IO.puts("#{count} jobs planned")
    end
  end
end
