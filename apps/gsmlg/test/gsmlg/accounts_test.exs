defmodule GSMLG.AccountsTest do
  use GSMLG.DataCase

  import ExUnit.CaptureLog

  alias GSMLG.Accounts

  describe "users" do
    alias GSMLG.Accounts.User

    import GSMLG.AccountsFixtures

    @invalid_attrs %{
      jti: nil,
      aud: nil,
      active_time: nil,
      apple_id: nil,
      email: nil,
      github_id: nil,
      google_id: nil,
      is_active: nil,
      name: nil,
      otp_token: nil,
      portrait: nil,
      verify_code: nil
    }

    setup do
      GSMLG.Repo.delete_all(GSMLG.Accounts.User)
      :ok
    end

    test "list_users/0 returns all users" do
      user = user_fixture()
      assert List.first(Accounts.list_users()).email == user.email
    end

    test "get_user!/1 returns the user with given id" do
      user = user_fixture()
      assert Accounts.get_user!(user.id).username == user.username
    end

    test "create_user/1 with valid data creates a user" do
      valid_attrs = %{
        email: "some@email",
        username: "some_name",
        password: "some password"
      }

      assert {:ok, %User{} = user} = Accounts.create_user(valid_attrs)
      assert user.email == "some@email"
      assert user.username == "some_name"
    end

    test "create_user/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_user(@invalid_attrs)
    end

    test "update_user/2 with valid data updates the user" do
      user = user_fixture()

      update_attrs = %{
        apple_id: "some updated apple_id",
        email: "updated@email",
        github_id: "some updated github_id",
        google_id: "some updated google_id",
        is_active: false,
        name: "some updated name",
        otp_token: "some updated otp_token",
        portrait: "some updated portrait"
      }

      assert {:ok, %User{} = user} = Accounts.update_user(user, update_attrs)
      assert user.email == update_attrs.email
      assert user.is_active == false
      assert user.name == "some updated name"
      assert user.otp_token == "some updated otp_token"
      assert user.portrait == "some updated portrait"
    end

    test "update_user/2 with invalid data returns error changeset" do
      user = user_fixture()
      assert {:ok, %User{}} = Accounts.update_user(user, @invalid_attrs)
      assert user != Accounts.get_user!(user.id)
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

  describe "user_tokens" do
    alias GSMLG.Accounts.UserToken

    import GSMLG.AccountsFixtures

    @invalid_attrs %{create_time: nil, expire_at: nil, id: nil, token: nil, token_type: nil}

    setup do
      GSMLG.Repo.delete_all(GSMLG.Accounts.UserToken)
      :ok
    end

    test "list_user_tokens/0 returns all user_tokens" do
      user_token = user_token_fixture()
      assert Accounts.list_user_tokens() == [user_token]
    end

    test "get_user_token!/1 returns the user_token with given id" do
      user_token = user_token_fixture()
      assert Accounts.get_user_token!(user_token.jti) == user_token
    end

    test "create_user_token/1 with valid data creates a user_token" do
      valid_attrs = %{
        typ: "jwt",
        iss: "issuer",
        jti: "7488a646-e31f-11e4-aace-600308960668",
        aud: "some token",
        sub: "user-id"
      }

      assert {:ok, %UserToken{} = user_token} = Accounts.create_user_token(valid_attrs)
      assert user_token.typ == "jwt"
      assert user_token.iss == "issuer"
      assert user_token.jti == "7488a646-e31f-11e4-aace-600308960668"
      assert user_token.aud == "some token"
      assert user_token.sub == "user-id"
    end

    test "create_user_token/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_user_token(@invalid_attrs)
    end

    test "update_user_token/2 with valid data updates the user_token" do
      user_token = user_token_fixture()

      update_attrs = %{
        iss: "gsmlg",
        jwt: "jwt.jwt.jwt",
        aud: "some updated token"
      }

      assert {:ok, %UserToken{} = user_token} =
               Accounts.update_user_token(user_token, update_attrs)

      assert user_token.aud == "some updated token"
      assert user_token.jwt == "jwt.jwt.jwt"
      assert user_token.iss == "gsmlg"
    end

    test "update_user_token/2 with invalid data returns error changeset" do
      user_token = user_token_fixture()

      assert {:error, %Ecto.Changeset{}} = Accounts.update_user_token(user_token, @invalid_attrs)
      assert user_token == Accounts.get_user_token!(user_token.jti)
    end

    test "delete_user_token/1 deletes the user_token" do
      user_token = user_token_fixture()
      assert {:ok, %UserToken{}} = Accounts.delete_user_token(user_token)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user_token!(user_token.jti) end
    end

    test "change_user_token/1 returns a user_token changeset" do
      user_token = user_token_fixture()
      assert %Ecto.Changeset{} = Accounts.change_user_token(user_token)
    end
  end

  describe "user client certificates" do
    alias GSMLG.Accounts.User
    alias GSMLG.Accounts.UserClientCertificate

    import GSMLG.AccountsFixtures

    test "binds DER to a user and loads its authoritative owner" do
      user = user_fixture()
      attrs = client_certificate_attrs()

      assert {:ok, %UserClientCertificate{} = binding} =
               Accounts.bind_user_client_certificate(user, attrs)

      expected_fingerprint =
        :crypto.hash(:sha256, attrs.certificate_der)
        |> Base.encode16(case: :lower)

      assert binding.user_id == user.id
      assert binding.certificate_der == attrs.certificate_der
      assert binding.fingerprint == expected_fingerprint
      assert binding.subject == attrs.subject
      assert binding.email == attrs.email

      loaded = Accounts.get_user_client_certificate_by_fingerprint(expected_fingerprint)
      assert %User{id: user_id} = loaded.user
      assert user_id == user.id
    end

    test "rebinding the same certificate to the same user is idempotent" do
      user = user_fixture()
      attrs = client_certificate_attrs()

      assert {:ok, first} = Accounts.bind_user_client_certificate(user, attrs)

      assert {:ok, second} =
               Accounts.bind_user_client_certificate(user, %{
                 attrs
                 | subject: "CN=Changed Display Value",
                   email: "changed@example.test"
               })

      assert second.id == first.id
      assert second.subject == attrs.subject
      assert second.email == attrs.email
    end

    test "a certificate cannot be rebound to another user" do
      owner = user_fixture(%{username: "cert_owner", email: "owner@example.test"})
      other = user_fixture(%{username: "cert_other", email: "other@example.test"})
      attrs = client_certificate_attrs()

      assert {:ok, binding} = Accounts.bind_user_client_certificate(owner, attrs)

      assert {:error, {:client_certificate_already_bound, owner_id}} =
               Accounts.bind_user_client_certificate(other, attrs)

      assert owner_id == owner.id

      assert Accounts.get_user_client_certificate_by_fingerprint(binding.fingerprint).user_id ==
               owner.id
    end

    test "one user can own multiple certificates and deletion cascades" do
      user = user_fixture()
      first = user_client_certificate_fixture(user)
      second = user_client_certificate_fixture(user)

      refute first.id == second.id
      assert {:ok, _user} = Accounts.delete_user(user)
      assert GSMLG.Repo.get(UserClientCertificate, first.id) == nil
      assert GSMLG.Repo.get(UserClientCertificate, second.id) == nil
    end

    test "binding does not log certificate values" do
      user = user_fixture()
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      attrs = %{
        certificate_der: "CERTIFICATE-DER-LOG-SENTINEL",
        subject: "CERTIFICATE-SUBJECT-LOG-SENTINEL",
        email: "CERTIFICATE-EMAIL-LOG-SENTINEL"
      }

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %UserClientCertificate{}} =
                   Accounts.bind_user_client_certificate(user, attrs)
        end)

      refute log =~ attrs.certificate_der
      refute log =~ attrs.subject
      refute log =~ attrs.email
    end
  end
end
