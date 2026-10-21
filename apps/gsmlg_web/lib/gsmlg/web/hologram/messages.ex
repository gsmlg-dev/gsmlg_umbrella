defmodule GSMLG.Web.Hologram.Messages do
  @moduledoc false

  @messages %{
    toolbox: {"toolbox", "Toolbox"},
    ip_geo: {"toolbox", "IP Geo"},
    whois: {"toolbox", "Whois"},
    mac_manufacturer: {"toolbox", "MAC Manufacturer"},
    svg2react: {"toolbox", "SVG to React"},
    svg_autocrop: {"toolbox", "SVG Autocrop"},
    ip_to_geomap: {"toolbox", "IP to GeoMap"},
    screensaver: {"toolbox", "Screen Saver"},
    ip_geo_description: {"default", "Query IP geolocation using MaxMind IP Geo databases"},
    whois_description: {"default", "Look up registration info for domains, IPs and ASNs"},
    mac_description: {"default", "Identify device vendors from MAC address OUI prefixes"},
    svg2react_description:
      {"default", "Convert SVG markup into clean React functional components"},
    svg_autocrop_description: {"default", "Remove excess whitespace and optimize SVG file size"},
    ip_to_geomap_description: {"default", "Visualize IP addresses on an interactive world map"},
    screensaver_description: {"default", "Ambient screensaver for display or presentation mode"},
    lookup: {"toolbox", "Lookup"},
    convert: {"toolbox", "Convert"},
    optimize: {"toolbox", "Optimize"},
    loading: {"toolbox", "Loading"},
    error: {"toolbox", "Error"},
    invalid_input: {"toolbox", "Invalid input"},
    browser_unavailable: {"toolbox", "Browser feature unavailable. Please try again."},
    open: {"default", "Open"},
    home: {"menu", "Home"},
    blog: {"menu", "Blog"},
    language: {"default", "Language"},
    theme: {"default", "Theme"},
    ip: {"toolbox", "IP"},
    query: {"toolbox", "Domain / IP / ASN"},
    protocol: {"toolbox", "Protocol"},
    short: {"toolbox", "Short"},
    full_information: {"toolbox", "Full Information"},
    unknown: {"toolbox", "Unknown"},
    continent: {"toolbox", "Continent"},
    country: {"toolbox", "Country"},
    city: {"toolbox", "City"},
    coordinates: {"toolbox", "Coordinates"},
    timeline: {"toolbox", "Timeline"},
    nameservers: {"toolbox", "Nameservers"},
    dnssec: {"toolbox", "DNSSEC"},
    signed: {"toolbox", "Signed"},
    unsigned: {"toolbox", "Unsigned"},
    registrar: {"toolbox", "Registrar"},
    abuse_contact: {"toolbox", "Abuse Contact"},
    links: {"toolbox", "Links"},
    key_tag: {"toolbox", "Key Tag"},
    algorithm: {"toolbox", "Algorithm"},
    digest: {"toolbox", "Digest"},
    origin_svg: {"toolbox", "Origin SVG"},
    optimized_svg: {"toolbox", "Optimized SVG"},
    start_fullscreen: {"toolbox", "start-fullscreen"}
  }

  def init(component, server) do
    locale = Hologram.Server.get_session(server, :locale, GSMLG.Locale.default())
    locale = if locale in GSMLG.Locale.supported(), do: locale, else: GSMLG.Locale.default()

    text =
      Gettext.with_locale(GSMLG.Web.Gettext, locale, fn ->
        Map.new(@messages, fn {key, {domain, message}} ->
          {key, Gettext.dgettext(GSMLG.Web.Gettext, domain, message)}
        end)
      end)

    Hologram.Component.put_state(component, text: text, locale: locale)
  end
end
