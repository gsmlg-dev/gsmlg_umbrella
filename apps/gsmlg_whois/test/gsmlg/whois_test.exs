defmodule GSMLG.WhoisTest do
  use ExUnit.Case
  doctest GSMLG.Whois

  alias GSMLG.Whois

  @tag :live
  test "lookup_raw/1 for domain" do
    case Whois.lookup_raw("google.com") do
      {:ok, list} ->
        {root_server, tld_output} = list |> hd()

        assert root_server =~ "whois.iana.org"
        assert tld_output =~ "com"

        {_tld_server, sld_output} = list |> Enum.at(1)
        assert sld_output =~ "GOOGLE.COM"
        assert sld_output =~ "Registry Domain ID: 2138514_DOMAIN_COM-VRSN"
        assert sld_output =~ "Creation Date: 1997-09-15T04:00:00Z"
        assert sld_output =~ "Registrar WHOIS Server: whois.markmonitor.com"

      {:error, :timeout} ->
        # Skip test on timeout - network issues
        :ok

      {:error, reason} ->
        flunk("Unexpected error: #{inspect(reason)}")
    end
  end

  @tag :live
  test "lookup_raw/2 for domain with custom :server" do
    wait()
    server = "whois.markmonitor.com"

    case Whois.lookup_raw("google.com", server: server) do
      {:ok, list} ->
        {whois_server, whois_output} = list |> hd()

        assert whois_server == server
        assert whois_output =~ "google.com"
        assert whois_output =~ "Google LLC"
        assert whois_output =~ "CA"
        assert whois_output =~ "US"

      {:error, :timeout} ->
        # Skip test on timeout - network issues
        :ok

      {:error, reason} ->
        flunk("Unexpected error: #{inspect(reason)}")
    end

    wait()
    server = %Whois.Server{host: "whois.markmonitor.com"}

    case Whois.lookup_raw("google.com", server: server) do
      {:ok, list} ->
        {whois_server, whois_output} = list |> hd()

        assert whois_server == server.host
        assert whois_output =~ "google.com"
        assert whois_output =~ "Google LLC"
        assert whois_output =~ "CA"
        assert whois_output =~ "US"

      {:error, :timeout} ->
        # Skip test on timeout - network issues
        :ok

      {:error, reason} ->
        flunk("Unexpected error: #{inspect(reason)}")
    end
  end

  @tag :live
  test "lookup_raw/1 for IP" do
    case Whois.lookup_raw("8.8.8.8") do
      {:ok, list} ->
        {_whois_server, whois_output} = list |> Enum.at(1)
        assert whois_output =~ "Google"

      {:error, :timeout} ->
        # Skip test on timeout - network issues
        :ok

      {:error, reason} ->
        flunk("Unexpected error: #{inspect(reason)}")
    end
  end

  @tag :live
  test "lookup_raw/1 for AS" do
    case Whois.lookup_raw("13335") do
      {:ok, list} ->
        {_whois_server, whois_output} = list |> Enum.at(1)
        assert whois_output =~ "Cloudflare"

      {:error, :timeout} ->
        # Skip test on timeout - network issues
        :ok

      {:error, reason} ->
        flunk("Unexpected error: #{inspect(reason)}")
    end
  end

  defp wait, do: Process.sleep(5000)
end
