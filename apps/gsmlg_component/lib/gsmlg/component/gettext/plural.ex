defmodule GSMLG.Component.Gettext.Plural do
  @moduledoc """
  Custom Gettext plural forms module that extends the default Gettext.Plural
  to support BCP 47 script subtag locales (e.g. `zh-Hans`, `zh-Hant`) which
  the default Gettext.Plural does not recognise.
  """

  @behaviour Gettext.Plural

  # Map BCP 47 hyphenated script-subtag locales to a base language that
  # Gettext.Plural does recognise, so plural forms resolve correctly.
  @locale_map %{
    "zh-Hans" => "zh",
    "zh-Hant" => "zh"
  }

  @impl Gettext.Plural
  def nplurals(locale), do: Gettext.Plural.nplurals(Map.get(@locale_map, locale, locale))

  @impl Gettext.Plural
  def plural(locale, n), do: Gettext.Plural.plural(Map.get(@locale_map, locale, locale), n)
end
