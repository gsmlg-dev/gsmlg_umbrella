defmodule GSMLG.Translation.ClaudeProviderTest do
  use ExUnit.Case, async: true

  alias GSMLG.Translation.ClaudeProvider

  setup do
    # Tesla.Mock adapter is configured in test.exs via
    # config :gsmlg, :claude_tesla_adapter, Tesla.Mock
    :ok
  end

  describe "translate/4 — not configured" do
    test "returns {:error, :not_configured} when api key is empty string" do
      Application.put_env(:gsmlg, :claude_api_key, "")

      assert {:error, :not_configured} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end

    test "returns {:error, :not_configured} when api key is not set" do
      Application.delete_env(:gsmlg, :claude_api_key)

      assert {:error, :not_configured} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    end
  end

  describe "translate/4 — successful response" do
    test "returns {:ok, %{title: _, content: _}} when API returns valid JSON" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      response_json = Jason.encode!(%{"title" => "Bonjour", "content" => "Contenu traduit"})

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{
               "content" => [%{"type" => "text", "text" => response_json}]
             }
           }}
      end)

      assert {:ok, %{title: "Bonjour", content: "Contenu traduit"}} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end

    test "handles Simplified Chinese as target locale" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      response_json = Jason.encode!(%{"title" => "你好", "content" => "翻译内容"})

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{
               "content" => [%{"type" => "text", "text" => response_json}]
             }
           }}
      end)

      assert {:ok, %{title: "你好", content: "翻译内容"}} =
               ClaudeProvider.translate("Hello", "Body text", "en", "zh-Hans")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end
  end

  describe "translate/4 — rate limited" do
    test "returns {:error, :rate_limited} on HTTP 429" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok, %Tesla.Env{status: 429, body: %{"error" => %{"message" => "rate limited"}}}}
      end)

      assert {:error, :rate_limited} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end
  end

  describe "translate/4 — API errors" do
    test "returns {:error, {:api_error, 500}} on server error" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok, %Tesla.Env{status: 500, body: %{"error" => "internal server error"}}}
      end)

      assert {:error, {:api_error, 500}} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end

    test "returns {:error, {:api_error, 401}} on unauthorized" do
      Application.put_env(:gsmlg, :claude_api_key, "bad-key")

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok, %Tesla.Env{status: 401, body: %{"error" => "unauthorized"}}}
      end)

      assert {:error, {:api_error, 401}} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end
  end

  describe "translate/4 — malformed JSON response" do
    test "returns {:error, :json_parse_error} when response text is not valid JSON" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{
               "content" => [%{"type" => "text", "text" => "not valid json at all"}]
             }
           }}
      end)

      assert {:error, :json_parse_error} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end

    test "returns {:error, :json_parse_error} when JSON is missing required keys" do
      Application.put_env(:gsmlg, :claude_api_key, "test-api-key")

      Tesla.Mock.mock(fn
        %Tesla.Env{method: :post, url: "https://api.anthropic.com/v1/messages"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{
               "content" => [
                 %{"type" => "text", "text" => Jason.encode!(%{"result" => "wrong key"})}
               ]
             }
           }}
      end)

      assert {:error, :json_parse_error} =
               ClaudeProvider.translate("Hello", "Body text", "en", "fr")
    after
      Application.delete_env(:gsmlg, :claude_api_key)
    end
  end
end
