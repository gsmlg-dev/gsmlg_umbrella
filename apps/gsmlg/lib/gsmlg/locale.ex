defmodule GSMLG.Locale do
  @moduledoc """
  BCP-47 locale constants for all languages supported by the platform.

  All listed locales are always enabled — no configuration required.
  """

  @supported ~w[en zh-Hans zh-Hant fr es de it ja]

  @doc "Returns the list of all supported BCP-47 locale codes."
  def supported, do: @supported

  @doc "Returns the configured default locale, falling back to zh-Hans."
  def default do
    :gsmlg
    |> Application.get_env(:i18n, [])
    |> Keyword.get(:default_locale, "zh-Hans")
  end
end
