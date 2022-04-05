defmodule GSMLGWeb.UserLiveTest do
  use GSMLGWeb.ConnCase

  import Phoenix.LiveViewTest
  import GSMLG.AccountsFixtures

  @create_attrs %{
    active_time: %{day: 4, hour: 17, minute: 34, month: 4, year: 2022},
    apple_id: "some apple_id",
    email: "some email",
    github_id: "some github_id",
    google_id: "some google_id",
    is_active: true,
    name: "some name",
    otp_token: "some otp_token",
    password: "some password",
    password_salt: "some password_salt",
    portrait: "some portrait",
    verify_code: 42
  }
  @update_attrs %{
    active_time: %{day: 5, hour: 17, minute: 34, month: 4, year: 2022},
    apple_id: "some updated apple_id",
    email: "some updated email",
    github_id: "some updated github_id",
    google_id: "some updated google_id",
    is_active: false,
    name: "some updated name",
    otp_token: "some updated otp_token",
    password: "some updated password",
    password_salt: "some updated password_salt",
    portrait: "some updated portrait",
    verify_code: 43
  }
  @invalid_attrs %{
    active_time: %{day: 30, hour: 17, minute: 34, month: 2, year: 2022},
    apple_id: nil,
    email: nil,
    github_id: nil,
    google_id: nil,
    is_active: false,
    name: nil,
    otp_token: nil,
    password: nil,
    password_salt: nil,
    portrait: nil,
    verify_code: nil
  }

  defp create_user(_) do
    user = user_fixture()
    %{user: user}
  end

  describe "Index" do
    setup [:create_user]

    test "lists all users", %{conn: conn, user: user} do
      {:ok, _index_live, html} = live(conn, Routes.user_index_path(conn, :index))

      assert html =~ "Listing Users"
      assert html =~ user.apple_id
    end

    test "saves new user", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, Routes.user_index_path(conn, :index))

      assert index_live |> element("a", "New User") |> render_click() =~
               "New User"

      assert_patch(index_live, Routes.user_index_path(conn, :new))

      assert index_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        index_live
        |> form("#user-form", user: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.user_index_path(conn, :index))

      assert html =~ "User created successfully"
      assert html =~ "some apple_id"
    end

    test "updates user in listing", %{conn: conn, user: user} do
      {:ok, index_live, _html} = live(conn, Routes.user_index_path(conn, :index))

      assert index_live |> element("#user-#{user.id} a", "Edit") |> render_click() =~
               "Edit User"

      assert_patch(index_live, Routes.user_index_path(conn, :edit, user))

      assert index_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        index_live
        |> form("#user-form", user: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.user_index_path(conn, :index))

      assert html =~ "User updated successfully"
      assert html =~ "some updated apple_id"
    end

    test "deletes user in listing", %{conn: conn, user: user} do
      {:ok, index_live, _html} = live(conn, Routes.user_index_path(conn, :index))

      assert index_live |> element("#user-#{user.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#user-#{user.id}")
    end
  end

  describe "Show" do
    setup [:create_user]

    test "displays user", %{conn: conn, user: user} do
      {:ok, _show_live, html} = live(conn, Routes.user_show_path(conn, :show, user))

      assert html =~ "Show User"
      assert html =~ user.apple_id
    end

    test "updates user within modal", %{conn: conn, user: user} do
      {:ok, show_live, _html} = live(conn, Routes.user_show_path(conn, :show, user))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit User"

      assert_patch(show_live, Routes.user_show_path(conn, :edit, user))

      assert show_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        show_live
        |> form("#user-form", user: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.user_show_path(conn, :show, user))

      assert html =~ "User updated successfully"
      assert html =~ "some updated apple_id"
    end
  end
end
