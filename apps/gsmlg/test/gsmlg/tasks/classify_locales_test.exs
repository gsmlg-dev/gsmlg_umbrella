defmodule Mix.Tasks.Blog.ClassifyLocalesTest do
  use GSMLG.DataCase

  import ExUnit.CaptureIO
  import GSMLG.ContentFixtures

  alias Mix.Tasks.Blog.ClassifyLocales

  describe "detect_locale/1" do
    test "detects CJK content as zh-Hans" do
      assert ClassifyLocales.detect_locale("这是中文内容 some text") == "zh-Hans"
    end

    test "detects Latin content as en" do
      assert ClassifyLocales.detect_locale("This is English content only") == "en"
    end

    test "detects CJK title as zh-Hans even with Latin content" do
      assert ClassifyLocales.detect_locale("中文标题 english body text") == "zh-Hans"
    end
  end

  describe "run/1 dry-run (default)" do
    test "prints summary table without updating DB" do
      blog =
        blog_fixture(%{
          title: "Hello World",
          content: "English content only",
          source_locale: "zh-Hans"
        })

      output =
        capture_io(fn ->
          ClassifyLocales.run([])
        end)

      assert output =~ to_string(blog.id)
      assert output =~ blog.slug
      assert output =~ "zh-Hans"
      assert output =~ "en"
      assert output =~ "posts processed"

      # DB should NOT be updated in dry-run
      reloaded = GSMLG.Content.get_blog!(blog.id)
      assert reloaded.source_locale == "zh-Hans"
    end

    test "dry-run flag explicitly also does not update DB" do
      blog =
        blog_fixture(%{
          title: "Hello World",
          content: "English content only",
          source_locale: "zh-Hans"
        })

      capture_io(fn ->
        ClassifyLocales.run(["--dry-run"])
      end)

      reloaded = GSMLG.Content.get_blog!(blog.id)
      assert reloaded.source_locale == "zh-Hans"
    end
  end

  describe "run/1 with --confirm" do
    test "updates source_locale in DB when content is English" do
      blog =
        blog_fixture(%{
          title: "Hello World",
          content: "English content only",
          source_locale: "zh-Hans"
        })

      output =
        capture_io(fn ->
          ClassifyLocales.run(["--confirm"])
        end)

      assert output =~ "posts processed"

      reloaded = GSMLG.Content.get_blog!(blog.id)
      assert reloaded.source_locale == "en"
    end

    test "updates source_locale in DB when content is Chinese" do
      blog =
        blog_fixture(%{
          title: "你好世界",
          content: "这是中文内容",
          source_locale: "en"
        })

      capture_io(fn ->
        ClassifyLocales.run(["--confirm"])
      end)

      reloaded = GSMLG.Content.get_blog!(blog.id)
      assert reloaded.source_locale == "zh-Hans"
    end
  end
end
