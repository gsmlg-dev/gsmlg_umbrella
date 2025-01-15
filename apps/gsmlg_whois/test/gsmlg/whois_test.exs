defmodule GSMLG.WhoisTest do
  use ExUnit.Case
  doctest GSMLG.Whois

  alias GSMLG.Whois

  @tag :live
  test "lookup_raw/1 for domain" do
    assert {:ok, list} = Whois.lookup_raw("google.com")
    {root_server, tld_output} = list |> hd()

    assert root_server =~ "whois.iana.org"
    assert tld_output =~ "com"

    {_tld_server, sld_output} = list |> Enum.at(1)
    assert sld_output =~ "GOOGLE.COM"
    assert sld_output =~ "Registry Domain ID: 2138514_DOMAIN_COM-VRSN"
    assert sld_output =~ "Creation Date: 1997-09-15T04:00:00Z"
    assert sld_output =~ "Registrar WHOIS Server: whois.markmonitor.com"
  end

  @tag :live
  test "lookup_raw/2 for domain with custom :server" do
    wait()
    server = "whois.markmonitor.com"
    assert {:ok, list} = Whois.lookup_raw("google.com", server: server)
    {whois_server, whois_output} = list |> hd()

    assert whois_server == server
    assert whois_output =~ "google.com"
    assert whois_output =~ "Google LLC"
    assert whois_output =~ "CA"
    assert whois_output =~ "US"

    wait()
    server = %Whois.Server{host: "whois.markmonitor.com"}
    assert {:ok, list} = Whois.lookup_raw("google.com", server: server)
    {whois_server, whois_output} = list |> hd()

    assert whois_server == server.host
    assert whois_output =~ "google.com"
    assert whois_output =~ "Google LLC"
    assert whois_output =~ "CA"
    assert whois_output =~ "US"
  end

  @tag :live
  test "lookup_raw/1 for IP" do
    assert {:ok, list} = Whois.lookup_raw("8.8.8.8")
    {_whois_server, whois_output} = list |> Enum.at(1)

    assert whois_output =~ "Google"
  end

  @tag :live
  test "lookup_raw/1 for AS" do
    assert {:ok, list} = Whois.lookup_raw("13335")
    {_whois_server, whois_output} = list |> Enum.at(1)

    assert whois_output =~ "Cloudflare"
  end

  defp wait, do: Process.sleep(2500)
end
