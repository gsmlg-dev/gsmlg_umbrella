defmodule Mix.Tasks.Blog.ClassifyLocales do
  @moduledoc """
  Classifies all blogs by detected locale based on CJK character presence.

  Prints a summary table of each blog showing its current `source_locale` and
  the detected locale. By default this is a dry-run — no changes are written to
  the database.

  ## Usage

      mix blog.classify_locales
      mix blog.classify_locales --confirm

  ## Options

    * `--confirm` — actually update `source_locale` in the database
    * `--dry-run` — explicit dry-run (default behaviour, no DB writes)

  """

  use Mix.Task

  @shortdoc "Classify blog source_locale based on CJK character detection"

  # CJK Unified Ideographs block: U+4E00–U+9FFF
  @cjk_start 0x4E00
  @cjk_end 0x9FFF

  @doc """
  Returns `"zh-Hans"` if `text` contains any CJK Unified Ideograph codepoints,
  otherwise returns `"en"`.
  """
  def detect_locale(text) do
    has_cjk =
      text
      |> String.codepoints()
      |> Enum.any?(fn cp ->
        case String.to_charlist(cp) do
          [code] -> code >= @cjk_start and code <= @cjk_end
          _ -> false
        end
      end)

    if has_cjk, do: "zh-Hans", else: "en"
  end

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [confirm: :boolean, dry_run: :boolean])

    confirm? = Keyword.get(opts, :confirm, false)

    blogs = GSMLG.Content.list_blogs()

    Enum.each(blogs, fn blog ->
      text = (blog.title || "") <> " " <> (blog.content || "")
      detected = detect_locale(text)

      IO.puts("[#{blog.id}] #{blog.slug}  #{blog.source_locale} → #{detected}")

      if confirm? do
        GSMLG.Content.update_blog(blog, %{source_locale: detected})
      end
    end)

    IO.puts("#{length(blogs)} posts processed")
  end
end
