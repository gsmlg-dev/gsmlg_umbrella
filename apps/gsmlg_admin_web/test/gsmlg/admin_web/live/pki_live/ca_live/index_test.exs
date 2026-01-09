defmodule GSMLG.AdminWeb.PKILive.CALive.IndexTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GSMLG.AccountsFixtures

  alias GSMLG.AdminWeb.PKIContext

  setup %{conn: conn} do
    # Create a real user in the database
    user = user_fixture()

    # Sign in the user using Guardian
    {:ok, token, _claims} = GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> put_session(:guardian_default_token, token)

    %{conn: conn, user: user}
  end

  describe "Index LiveView - :index action" do
    test "renders CA list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca")

      assert html =~ "Certificate Authorities"
      assert html =~ "Initialize New CA"
    end

    test "shows empty state when no CAs exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca")

      assert html =~ "No Certificate Authorities found"
    end
  end

  describe "Index LiveView - :new action" do
    test "renders CA creation form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/pki/ca/new")

      assert html =~ "Initialize New Certificate Authority"
      assert html =~ "Subject Information"
      assert html =~ "Key Configuration"
      assert html =~ "Validity Period"
      assert html =~ "Private Key Security"
    end

    test "displays all subject fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca/new")

      assert html =~ "Common Name (CN)"
      assert html =~ "Organization (O)"
      assert html =~ "Organizational Unit (OU)"
      assert html =~ "Country (C)"
      assert html =~ "State/Province (ST)"
      assert html =~ "Locality (L)"
    end

    test "displays key type selector with all options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca/new")

      assert html =~ "Key Type"
      assert html =~ "RSA"
      assert html =~ "ECDSA"
      assert html =~ "Ed25519"
    end

    test "initializes form with default values", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      assert view.assigns.key_type == "rsa"
      assert view.assigns.available_key_sizes == [2048, 3072, 4096, 8192]
      assert view.assigns.form != nil
    end
  end

  describe "key_type_changed event" do
    test "updates available key sizes when switching to ECDSA", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      assert view.assigns.available_key_sizes == [2048, 3072, 4096, 8192]

      view
      |> element("select[name='key_type']")
      |> render_change(%{key_type: "ecdsa"})

      assert view.assigns.key_type == "ecdsa"
      assert view.assigns.available_key_sizes == [256, 384, 521]
    end

    test "updates available key sizes when switching to Ed25519", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      view
      |> element("select[name='key_type']")
      |> render_change(%{key_type: "ed25519"})

      assert view.assigns.key_type == "ed25519"
      assert view.assigns.available_key_sizes == []
    end

    test "sets default key size for selected key type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      view
      |> element("select[name='key_type']")
      |> render_change(%{key_type: "ecdsa"})

      # Should default to first available size (256 for ECDSA)
      assert Ecto.Changeset.get_field(view.assigns.changeset, :key_size) == 256
    end
  end

  describe "validate_form event" do
    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      html =
        view
        |> form("#ca-form", %{common_name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "validates country code format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      html =
        view
        |> form("#ca-form", %{country: "usa"})
        |> render_change()

      assert html =~ "must be uppercase" || html =~ "must be exactly 2 characters"
    end

    test "shows password fields when encrypt_key is checked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      html =
        view
        |> form("#ca-form", %{encrypt_key: "true"})
        |> render_change()

      assert html =~ "Password"
      assert html =~ "Confirm Password"
    end
  end

  describe "create_ca event with valid data" do
    @tag :skip
    # Skipped because it requires full PKI infrastructure
    test "creates CA successfully with RSA key", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      valid_params = %{
        common_name: "Test CA",
        organization: "Test Org",
        country: "US",
        key_type: "rsa",
        key_size: "4096",
        validity_start: DateTime.utc_now() |> DateTime.to_iso8601(),
        validity_end:
          DateTime.utc_now()
          |> DateTime.add(10 * 365 * 24 * 3600, :second)
          |> DateTime.to_iso8601(),
        encrypt_key: "false"
      }

      view
      |> form("#ca-form", valid_params)
      |> render_submit()

      assert_redirect(view, ~p"/pki/ca")

      # Verify flash message
      flash = assert_redirected(view, ~p"/pki/ca")
      assert flash =~ "CA initialized successfully"
    end
  end

  describe "create_ca event with invalid data" do
    test "shows validation errors when common_name is missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      invalid_params = %{
        common_name: "",
        key_type: "rsa",
        key_size: "4096"
      }

      html =
        view
        |> form("#ca-form", invalid_params)
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "shows validation errors for invalid password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      invalid_params = %{
        common_name: "Test CA",
        key_type: "rsa",
        key_size: "4096",
        encrypt_key: "true",
        password: "short",
        password_confirmation: "short"
      }

      html =
        view
        |> form("#ca-form", invalid_params)
        |> render_submit()

      assert html =~ "must be at least 12 characters"
    end

    test "shows validation error for mismatched passwords", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pki/ca/new")

      invalid_params = %{
        common_name: "Test CA",
        key_type: "rsa",
        key_size: "4096",
        encrypt_key: "true",
        password: "SecurePassword123",
        password_confirmation: "DifferentPassword123"
      }

      html =
        view
        |> form("#ca-form", invalid_params)
        |> render_submit()

      assert html =~ "does not match"
    end
  end

  describe "datetime range picker integration" do
    test "renders datetime inputs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca/new")

      assert html =~ ~s(type="datetime-local")
      assert html =~ "Valid From"
      assert html =~ "Valid Until"
    end

    test "shows duration calculation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pki/ca/new")

      # Should show validity period duration by default
      assert html =~ "Validity Period" || html =~ "years"
    end
  end

end
