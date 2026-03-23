defmodule GSMLG.ApiProvidersTest do
  use GSMLG.DataCase, async: true

  alias GSMLG.ApiProviders
  alias GSMLG.ApiProvider

  import GSMLG.ApiProviderFixtures

  describe "list_api_providers/0" do
    test "returns all providers" do
      provider = api_provider_fixture()
      assert ApiProviders.list_api_providers() |> Enum.any?(&(&1.id == provider.id))
    end
  end

  describe "list_api_providers/1" do
    test "returns only providers of the given type" do
      _openai = api_provider_fixture(%{provider: "openai", name: "openai-1"})
      _github = api_provider_fixture(%{provider: "github", name: "github-1", credentials: %{token: "ghp_test"}})

      openai_providers = ApiProviders.list_api_providers("openai")
      assert Enum.all?(openai_providers, &(&1.provider == "openai"))
    end
  end

  describe "create_api_provider/1" do
    test "creates a provider with valid attributes" do
      attrs = %{provider: "openai", name: "default", credentials: %{api_key: "sk-test"}}
      assert {:ok, %ApiProvider{} = provider} = ApiProviders.create_api_provider(attrs)
      assert provider.provider == "openai"
      assert provider.name == "default"
      assert provider.credentials == %{api_key: "sk-test"}
      assert provider.active == true
    end

    test "credentials are encrypted at rest" do
      attrs = %{provider: "deepseek", name: "enc-test", credentials: %{api_key: "secret"}}
      assert {:ok, provider} = ApiProviders.create_api_provider(attrs)

      raw =
        GSMLG.Repo.query!(
          "SELECT credentials FROM api_providers WHERE provider = $1 AND name = $2",
          [provider.provider, provider.name]
        )

      [[raw_value]] = raw.rows
      assert String.starts_with?(raw_value, "v1:")
    end

    test "enforces unique provider + name" do
      attrs = %{provider: "cloudflare", name: "same", credentials: %{api_token: "tok"}}
      assert {:ok, _} = ApiProviders.create_api_provider(attrs)
      assert {:error, changeset} = ApiProviders.create_api_provider(attrs)
      assert {_, _} = changeset.errors[:provider]
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = ApiProviders.create_api_provider(%{})
      assert changeset.errors[:provider]
      assert changeset.errors[:name]
    end

    test "rejects invalid auth_type" do
      attrs = %{provider: "github", name: "bad-auth", credentials: %{token: "t"}, auth_type: "magic"}
      assert {:error, changeset} = ApiProviders.create_api_provider(attrs)
      assert changeset.errors[:auth_type]
    end
  end

  describe "update_api_provider/2" do
    test "updates provider attributes" do
      provider = api_provider_fixture()
      assert {:ok, updated} = ApiProviders.update_api_provider(provider, %{active: false})
      assert updated.active == false
    end

    test "updated credentials decrypt correctly" do
      provider = api_provider_fixture()
      new_creds = %{api_key: "sk-new-key"}
      assert {:ok, updated} = ApiProviders.update_api_provider(provider, %{credentials: new_creds})
      assert updated.credentials == new_creds
    end
  end

  describe "delete_api_provider/1" do
    test "removes the provider" do
      provider = api_provider_fixture()
      assert {:ok, _} = ApiProviders.delete_api_provider(provider)
      assert ApiProviders.get_api_provider_by(provider.provider, provider.name) == nil
    end
  end

  describe "get_api_provider_by/2" do
    test "returns the provider when found" do
      provider = api_provider_fixture(%{provider: "aws", name: "prod"})
      found = ApiProviders.get_api_provider_by("aws", "prod")
      assert found.id == provider.id
    end

    test "returns nil when not found" do
      assert ApiProviders.get_api_provider_by("nonexistent", "nope") == nil
    end
  end
end
