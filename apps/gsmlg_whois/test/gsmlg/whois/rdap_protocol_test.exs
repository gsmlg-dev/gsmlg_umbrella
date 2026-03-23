defmodule GSMLG.Whois.RDAPProtocolTest do
  use ExUnit.Case, async: true

  alias GSMLG.Whois.RDAPProtocol

  describe "module API" do
    test "lookup/2 and lookup/1 are public functions" do
      funs = RDAPProtocol.__info__(:functions)
      assert {:lookup, 2} in funs
      assert {:lookup, 1} in funs
    end
  end

  describe "type normalization in GSMLG.Whois.rdap_lookup/2" do
    alias GSMLG.Whois
    alias GSMLG.Whois.Cache

    setup do
      Cache.clear()
      :ok
    end

    test "cache key uses rdap: prefix for domain type" do
      data = %{"objectClassName" => "domain"}
      Cache.put("rdap:example.com", data, :rdap)

      assert {:ok, ^data} = Whois.rdap_lookup("example.com", type: :domain)
    end

    test "cache key uses rdap: prefix for ip type" do
      data = %{"objectClassName" => "ip network"}
      Cache.put("rdap:8.8.8.8", data, :rdap)

      assert {:ok, ^data} = Whois.rdap_lookup("8.8.8.8", type: :ip)
    end

    test "cache key uses rdap: prefix for asn type" do
      data = %{"objectClassName" => "autnum"}
      Cache.put("rdap:64496", data, :rdap)

      assert {:ok, ^data} = Whois.rdap_lookup("64496", type: :asn)
    end
  end
end
