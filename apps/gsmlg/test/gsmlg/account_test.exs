defmodule GSMLG.AccountTest do
  use GSMLG.DataCase

  alias GSMLG.Account

  describe "users" do
    alias GSMLG.Account.Auth

    import GSMLG.AccountFixtures

    @invalid_attrs %{}

    test "list_users/0 returns all users" do
      auth = auth_fixture()
      assert Account.list_users() == [auth]
    end

    test "get_auth!/1 returns the auth with given id" do
      auth = auth_fixture()
      assert Account.get_auth!(auth.id) == auth
    end

    test "create_auth/1 with valid data creates a auth" do
      valid_attrs = %{}

      assert {:ok, %Auth{} = auth} = Account.create_auth(valid_attrs)
    end

    test "create_auth/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Account.create_auth(@invalid_attrs)
    end

    test "update_auth/2 with valid data updates the auth" do
      auth = auth_fixture()
      update_attrs = %{}

      assert {:ok, %Auth{} = auth} = Account.update_auth(auth, update_attrs)
    end

    test "update_auth/2 with invalid data returns error changeset" do
      auth = auth_fixture()
      assert {:error, %Ecto.Changeset{}} = Account.update_auth(auth, @invalid_attrs)
      assert auth == Account.get_auth!(auth.id)
    end

    test "delete_auth/1 deletes the auth" do
      auth = auth_fixture()
      assert {:ok, %Auth{}} = Account.delete_auth(auth)
      assert_raise Ecto.NoResultsError, fn -> Account.get_auth!(auth.id) end
    end

    test "change_auth/1 returns a auth changeset" do
      auth = auth_fixture()
      assert %Ecto.Changeset{} = Account.change_auth(auth)
    end
  end
end
