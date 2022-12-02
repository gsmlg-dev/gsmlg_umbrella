defmodule GSMLG.WhoisTest do
  use ExUnit.Case
  doctest GSMLG.Whois

  alias GSMLG.Whois

  @tag :live
  test "lookup/1" do
    assert {:ok, record} = Whois.lookup("google.com")
    assert record.domain == "google.com"

    for type <- [:administrator, :registrant, :technical] do
      assert record.contacts[type].organization == "Google LLC"
      assert record.contacts[type].state == "CA"
      assert record.contacts[type].country == "US"
    end
  end

  @tag :live
  test "lookup/2 with custom :server" do
    wait()
    server = "whois.markmonitor.com"
    assert {:ok, record} = Whois.lookup("google.com", server: server)
    assert record.domain == "google.com"

    wait()
    server = %Whois.Server{host: "whois.markmonitor.com"}
    assert {:ok, record} = Whois.lookup("google.com", server: server)
    assert record.domain == "google.com"
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
