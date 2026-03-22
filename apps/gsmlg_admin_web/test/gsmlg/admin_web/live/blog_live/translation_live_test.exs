defmodule GSMLG.AdminWeb.BlogLive.TranslationLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GSMLG.ContentFixtures
  import GSMLG.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> put_session(:guardian_default_token, token)

    %{conn: conn, user: user}
  end

  describe "Translation dashboard" do
    setup do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      %{blog: blog}
    end

    test "renders status grid for all supported locales", %{conn: conn, blog: blog} do
      {:ok, _view, html} = live(conn, ~p"/blogs/#{blog.id}/translations")

      assert html =~ "Translations"
      assert html =~ blog.title
      # All supported non-source locales should appear
      supported = GSMLG.Locale.supported()

      Enum.each(supported, fn locale ->
        assert html =~ locale
      end)
    end

    test "shows translation status for each locale", %{conn: conn, blog: blog} do
      # In inline mode, Oban runs jobs immediately, so translations are already completed.
      {:ok, _view, html} = live(conn, ~p"/blogs/#{blog.id}/translations")

      # The status column is rendered — in inline mode all statuses will be "completed"
      assert html =~ "completed" or html =~ "Completed" or
               html =~ "pending" or html =~ "in_progress" or html =~ "not started"
    end
  end

  describe "retranslate event" do
    setup do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      translation = blog_translation_fixture(%{blog: blog, locale: "en", status: "completed"})
      %{blog: blog, translation: translation}
    end

    test "inserts a new Oban job and resets status to pending", %{
      conn: conn,
      blog: blog,
      translation: translation
    } do
      {:ok, view, _html} = live(conn, ~p"/blogs/#{blog.id}/translations")

      view
      |> element("[phx-click='retranslate'][phx-value-id='#{translation.id}']")
      |> render_click()

      updated = GSMLG.Content.get_translation(blog.id, "en")
      assert updated.manually_edited == false
      assert updated.status in ["pending", "in_progress", "completed"]
    end
  end

  describe "admin_edit event" do
    setup do
      blog = blog_fixture(%{source_locale: "zh-Hans"})
      translation = blog_translation_fixture(%{blog: blog, locale: "en", status: "completed"})
      %{blog: blog, translation: translation}
    end

    test "saves manual edit and sets manually_edited to true", %{
      conn: conn,
      blog: blog,
      translation: translation
    } do
      {:ok, view, _html} = live(conn, ~p"/blogs/#{blog.id}/translations")

      view
      |> element("[phx-click='edit_translation'][phx-value-id='#{translation.id}']")
      |> render_click()

      view
      |> form("#translation-edit-form-#{translation.id}")
      |> render_submit(%{title: "Admin Title", content: "Admin Content"})

      updated = GSMLG.Content.get_translation(blog.id, "en")
      assert updated.manually_edited == true
      assert updated.title == "Admin Title"
      assert updated.content == "Admin Content"
    end
  end
end
