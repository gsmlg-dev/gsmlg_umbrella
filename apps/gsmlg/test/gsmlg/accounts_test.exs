defmodule GSMLG.AccountsTest do
  use GSMLG.DataCase

  alias GSMLG.Accounts

  describe "users" do
    alias GSMLG.Accounts.User

    import GSMLG.AccountsFixtures

    @invalid_attrs %{
      active_time: nil,
      apple_id: nil,
      email: nil,
      github_id: nil,
      google_id: nil,
      is_active: nil,
      name: nil,
      otp_token: nil,
      password: nil,
      password_salt: nil,
      portrait: nil,
      verify_code: nil
    }

    test "list_users/0 returns all users" do
      user = user_fixture()
      assert Accounts.list_users() == [user]
    end

    test "get_user!/1 returns the user with given id" do
      user = user_fixture()
      assert Accounts.get_user!(user.id) == user
    end

    test "create_user/1 with valid data creates a user" do
      valid_attrs = %{
        active_time: ~U[2022-04-04 17:34:00Z],
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

      assert {:ok, %User{} = user} = Accounts.create_user(valid_attrs)
      assert user.active_time == ~U[2022-04-04 17:34:00Z]
      assert user.apple_id == "some apple_id"
      assert user.email == "some email"
      assert user.github_id == "some github_id"
      assert user.google_id == "some google_id"
      assert user.is_active == true
      assert user.name == "some name"
      assert user.otp_token == "some otp_token"
      assert user.password == "some password"
      assert user.password_salt == "some password_salt"
      assert user.portrait == "some portrait"
      assert user.verify_code == 42
    end

    test "create_user/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_user(@invalid_attrs)
    end

    test "update_user/2 with valid data updates the user" do
      user = user_fixture()

      update_attrs = %{
        active_time: ~U[2022-04-05 17:34:00Z],
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

      assert {:ok, %User{} = user} = Accounts.update_user(user, update_attrs)
      assert user.active_time == ~U[2022-04-05 17:34:00Z]
      assert user.apple_id == "some updated apple_id"
      assert user.email == "some updated email"
      assert user.github_id == "some updated github_id"
      assert user.google_id == "some updated google_id"
      assert user.is_active == false
      assert user.name == "some updated name"
      assert user.otp_token == "some updated otp_token"
      assert user.password == "some updated password"
      assert user.password_salt == "some updated password_salt"
      assert user.portrait == "some updated portrait"
      assert user.verify_code == 43
    end

    test "update_user/2 with invalid data returns error changeset" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, @invalid_attrs)
      assert user == Accounts.get_user!(user.id)
    end

    test "delete_user/1 deletes the user" do
      user = user_fixture()
      assert {:ok, %User{}} = Accounts.delete_user(user)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(user.id) end
    end

    test "change_user/1 returns a user changeset" do
      user = user_fixture()
      assert %Ecto.Changeset{} = Accounts.change_user(user)
    end
  end
end
