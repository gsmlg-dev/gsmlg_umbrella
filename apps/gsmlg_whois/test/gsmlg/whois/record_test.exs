defmodule GSMLG.Whois.RecordTest do
  use ExUnit.Case
  doctest GSMLG.Whois.Record

  alias GSMLG.Whois.Contact

  test "parse apple.com" do
    record = parse("apple.com")
    assert record.domain == "apple.com"

    assert record.nameservers == [
             "a.ns.apple.com",
             "b.ns.apple.com",
             "c.ns.apple.com",
             "d.ns.apple.com"
           ]

    assert record.registrar == "CSC CORPORATE DOMAINS, INC."
    assert_dt(record.created_at, ~D[1987-02-19])
    assert_dt(record.updated_at, ~D[2022-02-16])
    assert_dt(record.expires_at, ~D[2023-02-20])
  end

  test "parse apple.com contact" do
    for domain <- ["apple.com"] do
      record = parse(domain)

      for key <- [:registrant, :administrator, :technical] do
        assert Map.get(record.contacts, key) == %Contact{
                 name: "Domain Administrator",
                 organization: "Apple Inc.",
                 street: "One Apple Park Way",
                 city: "Cupertino",
                 state: "CA",
                 zip: "95014",
                 country: "US",
                 phone: "+1.4089961010",
                 fax: "+1.4089741560",
                 email: if(key == :technical, do: "apple-noc@apple.com", else: "domains@apple.com")
               }
      end
    end
  end

  defp parse(domain) do
    "../../fixtures/raw/#{domain}"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> GSMLG.Whois.Record.parse()
  end

  defp assert_dt(datetime, date) do
    assert NaiveDateTime.to_date(datetime) == date
  end
end
