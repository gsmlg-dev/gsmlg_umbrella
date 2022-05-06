defmodule GSMLGWeb.UserTokenLiveTest do
  use GSMLGWeb.ConnCase

  import Phoenix.LiveViewTest
  import GSMLG.AccountsFixtures

  @create_attrs %{
    create_time: %{day: 6, hour: 16, minute: 16, month: 4, year: 2022},
    expire_at: %{day: 6, hour: 16, minute: 16, month: 4, year: 2022},
    id: "7488a646-e31f-11e4-aace-600308960662",
    token: "some token",
    token_type: "some token_type"
  }
  @update_attrs %{
    create_time: %{day: 7, hour: 16, minute: 16, month: 4, year: 2022},
    expire_at: %{day: 7, hour: 16, minute: 16, month: 4, year: 2022},
    id: "7488a646-e31f-11e4-aace-600308960668",
    token: "some updated token",
    token_type: "some updated token_type"
  }
  @invalid_attrs %{
    create_time: %{day: 30, hour: 16, minute: 16, month: 2, year: 2022},
    expire_at: %{day: 30, hour: 16, minute: 16, month: 2, year: 2022},
    id: nil,
    token: nil,
    token_type: nil
  }

  defp create_user_token(_) do
    user_token = user_token_fixture()
    %{user_token: user_token}
  end

  # describe "Index" do
  #   setup [:create_user_token]

  #   test "lists all user_tokens", %{conn: conn, user_token: user_token} do
  #     {:ok, _index_live, html} = live(conn, Routes.user_token_index_path(conn, :index))

  #     assert html =~ "Listing User tokens"
  #     assert html =~ user_token.token
  #   end

  #   test "saves new user_token", %{conn: conn} do
  #     {:ok, index_live, _html} = live(conn, Routes.user_token_index_path(conn, :index))

  #     assert index_live |> element("a", "New User token") |> render_click() =~
  #              "New User token"

  #     assert_patch(index_live, Routes.user_token_index_path(conn, :new))

  #     assert index_live
  #            |> form("#user_token-form", user_token: @invalid_attrs)
  #            |> render_change() =~ "is invalid"

  #     {:ok, _, html} =
  #       index_live
  #       |> form("#user_token-form", user_token: @create_attrs)
  #       |> render_submit()
  #       |> follow_redirect(conn, Routes.user_token_index_path(conn, :index))

  #     assert html =~ "User token created successfully"
  #     assert html =~ "some token"
  #   end

  #   test "updates user_token in listing", %{conn: conn, user_token: user_token} do
  #     {:ok, index_live, _html} = live(conn, Routes.user_token_index_path(conn, :index))

  #     assert index_live |> element("#user_token-#{user_token.id} a", "Edit") |> render_click() =~
  #              "Edit User token"

  #     assert_patch(index_live, Routes.user_token_index_path(conn, :edit, user_token))

  #     assert index_live
  #            |> form("#user_token-form", user_token: @invalid_attrs)
  #            |> render_change() =~ "is invalid"

  #     {:ok, _, html} =
  #       index_live
  #       |> form("#user_token-form", user_token: @update_attrs)
  #       |> render_submit()
  #       |> follow_redirect(conn, Routes.user_token_index_path(conn, :index))

  #     assert html =~ "User token updated successfully"
  #     assert html =~ "some updated token"
  #   end

  #   test "deletes user_token in listing", %{conn: conn, user_token: user_token} do
  #     {:ok, index_live, _html} = live(conn, Routes.user_token_index_path(conn, :index))

  #     assert index_live |> element("#user_token-#{user_token.id} a", "Delete") |> render_click()
  #     refute has_element?(index_live, "#user_token-#{user_token.id}")
  #   end
  # end

  # describe "Show" do
  #   setup [:create_user_token]

  #   test "displays user_token", %{conn: conn, user_token: user_token} do
  #     {:ok, _show_live, html} = live(conn, Routes.user_token_show_path(conn, :show, user_token))

  #     assert html =~ "Show User token"
  #     assert html =~ user_token.token
  #   end

  #   test "updates user_token within modal", %{conn: conn, user_token: user_token} do
  #     {:ok, show_live, _html} = live(conn, Routes.user_token_show_path(conn, :show, user_token))

  #     assert show_live |> element("a", "Edit") |> render_click() =~
  #              "Edit User token"

  #     assert_patch(show_live, Routes.user_token_show_path(conn, :edit, user_token))

  #     assert show_live
  #            |> form("#user_token-form", user_token: @invalid_attrs)
  #            |> render_change() =~ "is invalid"

  #     {:ok, _, html} =
  #       show_live
  #       |> form("#user_token-form", user_token: @update_attrs)
  #       |> render_submit()
  #       |> follow_redirect(conn, Routes.user_token_show_path(conn, :show, user_token))

  #     assert html =~ "User token updated successfully"
  #     assert html =~ "some updated token"
  #   end
  # end
end
