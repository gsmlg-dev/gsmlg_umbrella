defmodule GSMLG.Web.Components.LanguageSwitcher do
  @moduledoc """
  Language switcher component for the site footer.

  Renders a list of links that switch the display language via the `?lang=` parameter.
  The current locale is highlighted. Native language names are shown.
  """

  use Phoenix.Component

  @locale_names %{
    "zh-Hans" => "简体中文",
    "zh-Hant" => "繁體中文",
    "en" => "English",
    "fr" => "Français",
    "es" => "Español",
    "de" => "Deutsch",
    "it" => "Italiano",
    "ja" => "日本語"
  }

  attr :locale, :string, required: true, doc: "Currently active locale"
  attr :supported_locales, :list, required: true, doc: "List of BCP-47 locale codes to display"

  def language_switcher(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <a
        :for={loc <- @supported_locales}
        href={"?lang=#{loc}"}
        class={[
          "text-sm transition-opacity",
          if(loc == @locale, do: "font-semibold opacity-100", else: "opacity-60 hover:opacity-100")
        ]}
        aria-current={if loc == @locale, do: "true", else: "false"}
      >
        {locale_display_name(loc)}
      </a>
    </div>
    """
  end

  defp locale_display_name(locale) do
    Map.get(@locale_names, locale, locale)
  end
end
