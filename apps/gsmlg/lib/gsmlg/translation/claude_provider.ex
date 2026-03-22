defmodule GSMLG.Translation.ClaudeProvider do
  @moduledoc """
  Claude AI translation provider implementing the `GSMLG.Translation.Provider` behaviour.

  This provider calls the configured AI API to translate blog content.
  Configure the API endpoint via Application config:

      config :gsmlg, :claude_api_key, "your-api-key"
  """

  @behaviour GSMLG.Translation.Provider

  @impl true
  def translate(title, content, source_locale, target_locale) do
    api_key = Application.get_env(:gsmlg, :claude_api_key, "")

    if api_key == "" do
      {:error, :not_configured}
    else
      do_translate(title, content, source_locale, target_locale, api_key)
    end
  end

  defp do_translate(title, content, source_locale, target_locale, _api_key) do
    # TODO: Implement actual Claude API call
    # For now, return a not-implemented error so jobs can be observed
    _ = {title, content, source_locale, target_locale}
    {:error, :not_implemented}
  end
end
