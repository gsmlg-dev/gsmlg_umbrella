defmodule GSMLG.Translation.ClaudeProvider do
  @moduledoc """
  Claude AI translation provider implementing the `GSMLG.Translation.Provider` behaviour.

  Configuration is read from the `translation_provider_settings` database row (managed via
  the admin UI). Falls back to Application config if no DB row exists:

      config :gsmlg, :claude_api_key, "your-api-key"
      config :gsmlg, :claude_translation_model, "claude-haiku-4-5-20251001"
  """

  @behaviour GSMLG.Translation.Provider

  @locale_names %{
    "zh-Hans" => "Simplified Chinese",
    "zh-Hant" => "Traditional Chinese",
    "en" => "English",
    "fr" => "French",
    "es" => "Spanish",
    "de" => "German",
    "it" => "Italian",
    "ja" => "Japanese"
  }

  @impl true
  def translate(title, content, source_locale, target_locale) do
    setting = GSMLG.Content.get_translation_provider_setting()

    api_key =
      case setting.api_key do
        key when is_binary(key) and key != "" -> key
        _ -> Application.get_env(:gsmlg, :claude_api_key, "")
      end

    if api_key == "" do
      {:error, :not_configured}
    else
      model =
        case setting.model do
          m when is_binary(m) and m != "" -> m
          _ -> Application.get_env(:gsmlg, :claude_translation_model, "claude-haiku-4-5-20251001")
        end

      prompt = build_system_prompt(setting.system_prompt, source_locale, target_locale)
      do_translate(title, content, prompt, model, api_key)
    end
  end

  defp build_system_prompt(nil, source_locale, target_locale),
    do: default_system_prompt(source_locale, target_locale)

  defp build_system_prompt("", source_locale, target_locale),
    do: default_system_prompt(source_locale, target_locale)

  defp build_system_prompt(template, source_locale, target_locale) do
    source_name = Map.get(@locale_names, source_locale, source_locale)
    target_name = Map.get(@locale_names, target_locale, target_locale)

    template
    |> String.replace("{source}", source_name)
    |> String.replace("{target}", target_name)
  end

  defp default_system_prompt(source_locale, target_locale) do
    source_name = Map.get(@locale_names, source_locale, source_locale)
    target_name = Map.get(@locale_names, target_locale, target_locale)

    """
    You are a professional translator. Translate the following blog post from #{source_name} to #{target_name}.
    Preserve all Markdown formatting exactly as-is.
    Return ONLY a JSON object with exactly two keys: "title" and "content".
    Do not include any explanation or text outside the JSON object.
    """
  end

  defp do_translate(title, content, system_prompt, model, api_key) do
    client = build_client(api_key)

    body = %{
      model: model,
      max_tokens: 4096,
      system: system_prompt,
      messages: [
        %{role: "user", content: "Title: #{title}\n\nContent:\n#{content}"}
      ]
    }

    case Tesla.post(client, "/v1/messages", body) do
      {:ok, %Tesla.Env{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_translation(text)

      {:ok, %Tesla.Env{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Tesla.Env{status: status}} when status >= 400 ->
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_client(api_key) do
    adapter =
      Application.get_env(
        :gsmlg,
        :claude_tesla_adapter,
        {Tesla.Adapter.Finch, name: GSMLG.Finch, receive_timeout: 30_000}
      )

    Tesla.client(
      [
        {Tesla.Middleware.BaseUrl, "https://api.anthropic.com"},
        Tesla.Middleware.JSON,
        {Tesla.Middleware.Headers,
         [
           {"x-api-key", api_key},
           {"anthropic-version", "2023-06-01"}
         ]}
      ],
      adapter
    )
  end

  defp parse_translation(text) do
    case Jason.decode(text) do
      {:ok, %{"title" => t, "content" => c}} when is_binary(t) and is_binary(c) ->
        {:ok, %{title: t, content: c}}

      _ ->
        {:error, :json_parse_error}
    end
  end
end
