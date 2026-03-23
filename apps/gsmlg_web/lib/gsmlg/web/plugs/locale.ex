defmodule GSMLG.Web.Plugs.Locale do
  @moduledoc """
  Resolves the visitor's preferred locale and assigns it to `conn.assigns.current_locale`.

  Resolution order (first match wins):
  1. `?lang=` query parameter
  2. `locale` session value
  3. `Accept-Language` HTTP header (first supported tag wins)
  4. Config default (`Application.get_env(:gsmlg, :i18n)[:default_locale]`)

  The resolved locale is saved to session and set on Gettext.
  """

  import Plug.Conn

  # BCP-47 region → script tag mappings for common Chinese variants
  @bcp47_map %{
    "zh-CN" => "zh-Hans",
    "zh-SG" => "zh-Hans",
    "zh-TW" => "zh-Hant",
    "zh-HK" => "zh-Hant",
    "zh-MO" => "zh-Hant",
    "zh" => "zh-Hans"
  }

  def init(opts), do: opts

  def call(conn, _opts) do
    supported = supported_locales()
    default = default_locale()

    locale =
      resolve_locale(conn, supported) || default

    conn
    |> put_session("locale", locale)
    |> assign(:current_locale, locale)
    |> tap(fn _ -> Gettext.put_locale(GSMLG.Web.Gettext, locale) end)
  end

  # --- Private resolution helpers ---

  defp resolve_locale(conn, supported) do
    with nil <- from_param(conn, supported),
         nil <- from_session(conn, supported),
         nil <- from_accept_language(conn, supported) do
      nil
    end
  end

  defp from_param(%{params: params} = _conn, supported) do
    case Map.get(params, "lang") do
      nil -> nil
      tag -> normalize_and_check(tag, supported)
    end
  end

  defp from_param(_conn, _supported), do: nil

  defp from_session(conn, supported) do
    case get_session(conn, "locale") do
      nil -> nil
      tag -> normalize_and_check(tag, supported)
    end
  end

  defp from_accept_language(conn, supported) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language(supported)
  end

  defp parse_accept_language(nil, _supported), do: nil

  defp parse_accept_language(header, supported) do
    header
    |> String.split(",")
    |> Enum.map(&extract_tag/1)
    |> Enum.find_value(&normalize_and_check(&1, supported))
  end

  defp extract_tag(segment) do
    segment
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp normalize_and_check(tag, supported) do
    normalized = Map.get(@bcp47_map, tag, tag)

    cond do
      normalized in supported ->
        normalized

      # Try language prefix match (e.g. "en-GB" → "en")
      prefix = String.split(normalized, "-") |> List.first() ->
        Enum.find(supported, &(String.starts_with?(&1, prefix <> "-") or &1 == prefix))
    end
  end

  defp supported_locales, do: GSMLG.Locale.supported()

  defp default_locale, do: GSMLG.Locale.default()
end
