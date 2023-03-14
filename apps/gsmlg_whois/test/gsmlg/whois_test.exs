defmodule GSMLG.WhoisTest do
  use ExUnit.Case
  doctest GSMLG.Whois

  alias GSMLG.Whois

  @tag :live
  test "lookup_domain_raw/1" do
    assert {:ok, output} = Whois.lookup_domain_raw("google.com")

    assert output =~ "google.com"
    assert output =~ "Google LLC"
    assert output =~ "CA"
    assert output =~ "US"
  end

  @tag :live
  test "lookup_domain_raw/2 with custom :server" do
    wait()
    server = "whois.markmonitor.com"
    assert {:ok, output} = Whois.lookup_domain_raw("google.com", server: server)

    assert output =~ "google.com"
    assert output =~ "Google LLC"
    assert output =~ "CA"
    assert output =~ "US"

    wait()
    server = %Whois.Server{host: "whois.markmonitor.com"}
    assert {:ok, output} = Whois.lookup_domain_raw("google.com", server: server)

    assert output =~ "google.com"
    assert output =~ "Google LLC"
    assert output =~ "CA"
    assert output =~ "US"
  end

  @tag :live
  test "lookup_ip_raw/1" do
    assert {:ok, out} = Whois.lookup_ip_raw("8.8.8.8")

    assert out =~ "Google"
  end

  @tag :live
  test "lookup_as_raw/1" do
    assert {:ok, out} = Whois.lookup_as_raw("13335")

    assert out =~ "Cloudflare"
  end

  defp wait, do: Process.sleep(2500)
end
