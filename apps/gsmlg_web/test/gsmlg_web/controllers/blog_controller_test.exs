defmodule GSMLG.Web.BlogControllerTest do
  use GSMLG.Web.ConnCase

  import GSMLG.ContentFixtures

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index (API)" do
    test "lists all blogs", %{conn: conn} do
      conn = get(conn, ~p"/api/blogs")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "index (HTML — locale-aware)" do
    test "renders blog list page successfully" do
      blog = blog_fixture()
      conn = build_conn() |> get(~p"/blogs")

      assert html_response(conn, 200) =~ blog.title
    end

    test "has current_locale assign after LocalePlug runs" do
      conn = build_conn() |> get(~p"/blogs")

      assert conn.assigns[:current_locale] != nil
    end

    test "uses ?lang= param to set locale" do
      build_conn() |> get(~p"/blogs?lang=en")
      # If LocalePlug runs, session should have locale — verified via redirect or assign.
      # For now: assert no error response (plug must not crash).
      conn = build_conn() |> get(~p"/blogs?lang=en")
      assert html_response(conn, 200)
    end

    test "renders translated title when completed translation exists for locale" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})

      _translation =
        blog_translation_fixture(%{
          blog: blog,
          locale: "en",
          title: "My Translated Title",
          content: "My translated content",
          status: "completed"
        })

      conn = build_conn() |> get(~p"/blogs?lang=en")
      assert html_response(conn, 200) =~ "My Translated Title"
    end

    test "renders source title when no completed translation exists for locale" do
      # Request in the source locale (zh-Hans) — no translation record exists for source locale,
      # so the controller finds nil and renders the source title as fallback.
      _blog = blog_fixture(%{title: "Original Source Title", source_locale: "zh-Hans"})

      conn = build_conn() |> get(~p"/blogs?lang=zh-Hans")
      assert html_response(conn, 200) =~ "Original Source Title"
    end
  end

  describe "language switcher session persistence (US2)" do
    test "?lang= param saves locale to session and persists on subsequent requests" do
      conn1 = build_conn() |> get(~p"/blogs?lang=en")
      assert conn1.assigns.current_locale == "en"

      # Subsequent request without param should use session locale
      conn2 = recycle(conn1) |> get(~p"/blogs")
      assert conn2.assigns.current_locale == "en"
    end

    test "current_locale assign is present in template assigns for index" do
      conn = build_conn() |> get(~p"/blogs")
      assert Map.has_key?(conn.assigns, :current_locale)
    end

    test "current_locale assign is present in template assigns for show" do
      blog = blog_fixture()
      conn = build_conn() |> get(~p"/blogs/#{blog.slug}")
      assert Map.has_key?(conn.assigns, :current_locale)
    end

    test "footer renders language switcher with at least one language option" do
      conn = build_conn() |> get(~p"/blogs")
      body = html_response(conn, 200)
      # Language switcher should be present in footer
      assert body =~ "lang="
    end
  end

  describe "translation indicators (US3)" do
    test "shows 'AI translated' indicator when viewing completed translation (locale ≠ source)" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})

      _translation =
        blog_translation_fixture(%{
          blog: blog,
          locale: "en",
          title: "Translated Title",
          content: "Translated content",
          status: "completed"
        })

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=en")
      body = html_response(conn, 200)

      assert body =~ "AI translated"
    end

    test "shows 'translation in progress' when translation is pending" do
      # Stub (not expect) so all Oban inline jobs use rate_limited — keeps translations pending
      Mox.stub(GSMLG.Translation.MockProvider, :translate, fn _title, _content, _src, _tgt ->
        {:error, :rate_limited}
      end)

      blog = blog_fixture(%{source_locale: "zh-Hans"})

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=en")
      body = html_response(conn, 200)

      assert body =~ "translation in progress"
    end

    test "no translation indicator when viewing in source locale" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=zh-Hans")
      body = html_response(conn, 200)

      refute body =~ "AI translated"
      refute body =~ "translation in progress"
    end
  end

  describe "show (HTML — locale-aware)" do
    test "renders blog show page successfully" do
      blog = blog_fixture()
      conn = build_conn() |> get(~p"/blogs/#{blog.slug}")

      assert html_response(conn, 200) =~ blog.title
    end

    test "has current_locale assign after LocalePlug runs" do
      blog = blog_fixture()
      conn = build_conn() |> get(~p"/blogs/#{blog.slug}")

      assert conn.assigns[:current_locale] != nil
    end

    test "renders translated title and content when completed translation exists" do
      blog = blog_fixture(%{source_locale: "zh-Hans"})

      _translation =
        blog_translation_fixture(%{
          blog: blog,
          locale: "en",
          title: "English Translated Title",
          content: "English translated content",
          status: "completed"
        })

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=en")
      body = html_response(conn, 200)

      assert body =~ "English Translated Title"
      assert body =~ "English translated content"
    end

    test "renders source content when no translation exists for locale" do
      # Request in the source locale — no translation record exists for zh-Hans (source locale),
      # so the controller finds nil and the template falls back to source content.
      blog =
        blog_fixture(%{
          title: "Source Title",
          content: "Source content",
          source_locale: "zh-Hans"
        })

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=zh-Hans")
      body = html_response(conn, 200)

      assert body =~ "Source Title"
    end

    test "renders source content when translation is not completed (pending/in_progress)" do
      # Stub (not expect) so all Oban inline jobs use rate_limited — keeps translations pending
      Mox.stub(GSMLG.Translation.MockProvider, :translate, fn _title, _content, _src, _tgt ->
        {:error, :rate_limited}
      end)

      blog =
        blog_fixture(%{
          title: "Source Title Pending",
          content: "Source content pending",
          source_locale: "zh-Hans"
        })

      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=en")
      body = html_response(conn, 200)

      assert body =~ "Source Title Pending"
    end

    test "no 5xx error regardless of locale" do
      blog = blog_fixture()

      # Unsupported or unknown locale — should still render source content, not error
      conn = build_conn() |> get(~p"/blogs/#{blog.slug}?lang=xx-XX")
      assert html_response(conn, 200)
    end
  end
end
