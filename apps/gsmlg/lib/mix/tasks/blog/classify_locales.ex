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

  import Ecto.Query, only: [from: 2]

  @shortdoc "Classify blog source_locale based on CJK character detection"

  # CJK Unified Ideographs block: U+4E00–U+9FFF (shared by Chinese and Japanese Kanji)
  @cjk_start 0x4E00
  @cjk_end 0x9FFF
  # Hiragana: U+3040–U+309F (Japanese-exclusive)
  @hiragana_start 0x3040
  @hiragana_end 0x309F
  # Katakana: U+30A0–U+30FF (Japanese-exclusive)
  @katakana_start 0x30A0
  @katakana_end 0x30FF

  @doc """
  Detects the locale of `text` based on Unicode character ranges.

  Returns `"ja"` if the text contains Hiragana or Katakana (Japanese-exclusive scripts),
  `"zh-Hans"` if it contains CJK Unified Ideographs (Chinese/Kanji) without Japanese kana,
  or `"en"` otherwise.
  """
  def detect_locale(text) do
    codepoints = String.to_charlist(text)

    has_japanese =
      Enum.any?(codepoints, fn code ->
        (code >= @hiragana_start and code <= @hiragana_end) or
          (code >= @katakana_start and code <= @katakana_end)
      end)

    has_cjk =
      Enum.any?(codepoints, fn code ->
        code >= @cjk_start and code <= @cjk_end
      end)

    cond do
      has_japanese -> "ja"
      has_cjk -> "zh-Hans"
      true -> "en"
    end
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

      if confirm? and blog.source_locale != detected do
        GSMLG.Repo.update_all(
          from(b in GSMLG.Content.Blog, where: b.id == ^blog.id),
          set: [source_locale: detected]
        )
      end
    end)

    IO.puts("#{length(blogs)} posts processed")
  end
end
