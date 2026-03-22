defmodule GSMLG.Translation.Provider do
  @moduledoc """
  Behaviour for AI translation providers.

  Implement this behaviour to provide a concrete translation backend.
  Configure the implementation via `Application.get_env(:gsmlg, :translation_provider)`.
  """

  @doc """
  Translates a blog post title and content from `source_locale` to `target_locale`.

  Returns `{:ok, %{title: translated_title, content: translated_content}}` on success,
  or `{:error, reason}` on failure.

  ## Error reasons
  - `:not_found` — source content missing, do not retry
  - `:rate_limited` — provider rate limit hit, snooze and retry
  - Any other term — transient error, retry with backoff
  """
  @callback translate(
              title :: String.t(),
              content :: String.t(),
              source_locale :: String.t(),
              target_locale :: String.t()
            ) :: {:ok, %{title: String.t(), content: String.t()}} | {:error, term()}
end
