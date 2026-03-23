defmodule GSMLG.Web.Plugs.LocaleTest do
  use GSMLG.Web.ConnCase, async: true

  alias GSMLG.Web.Plugs.Locale

  describe "init/1" do
    test "returns opts unchanged" do
      assert Locale.init([]) == []
    end
  end

  describe "call/2 — resolution priority" do
    test "uses ?lang= query param when present" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{"lang" => "en"})

      assert conn.assigns.current_locale == "en"
    end

    test "falls back to session locale when no query param" do
      conn =
        build_conn()
        |> init_test_session(%{"locale" => "en"})
        |> get_locale_conn(%{})

      assert conn.assigns.current_locale == "en"
    end

    test "falls back to Accept-Language header when no param or session" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "zh-Hans,zh;q=0.9,en;q=0.8")
        |> init_test_session(%{})
        |> get_locale_conn(%{})

      assert conn.assigns.current_locale == "zh-Hans"
    end

    test "falls back to config default when no other source" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{})

      default = get_default_locale()
      assert conn.assigns.current_locale == default
    end

    test "query param takes priority over session and header" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "zh-Hans")
        |> init_test_session(%{"locale" => "zh-Hans"})
        |> get_locale_conn(%{"lang" => "en"})

      assert conn.assigns.current_locale == "en"
    end

    test "session takes priority over Accept-Language header" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "zh-Hans")
        |> init_test_session(%{"locale" => "en"})
        |> get_locale_conn(%{})

      assert conn.assigns.current_locale == "en"
    end
  end

  describe "call/2 — BCP-47 variant mapping" do
    test "maps zh-CN to zh-Hans" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{"lang" => "zh-CN"})

      assert conn.assigns.current_locale == "zh-Hans"
    end

    test "maps zh-TW to zh-Hant" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{"lang" => "zh-TW"})

      assert conn.assigns.current_locale == "zh-Hant"
    end

    test "maps zh to zh-Hans (Simplified as default script for Chinese)" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "zh")
        |> init_test_session(%{})
        |> get_locale_conn(%{})

      assert conn.assigns.current_locale == "zh-Hans"
    end
  end

  describe "call/2 — unsupported locale fallback" do
    test "falls back to config default for unsupported locale" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{"lang" => "xx-XX"})

      default = get_default_locale()
      assert conn.assigns.current_locale == default
    end

    test "falls back when Accept-Language has only unsupported locales" do
      conn =
        build_conn()
        |> put_req_header("accept-language", "xx-XX, yy;q=0.9")
        |> init_test_session(%{})
        |> get_locale_conn(%{})

      default = get_default_locale()
      assert conn.assigns.current_locale == default
    end
  end

  describe "call/2 — session persistence" do
    test "saves resolved locale to session" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get_locale_conn(%{"lang" => "en"})

      assert get_session(conn, "locale") == "en"
    end
  end

  # Helper to simulate plug call in router context
  defp get_locale_conn(conn, params) do
    conn
    |> Map.put(:params, params)
    |> Locale.call(Locale.init([]))
  end

  defp get_default_locale, do: GSMLG.Locale.default()
end
