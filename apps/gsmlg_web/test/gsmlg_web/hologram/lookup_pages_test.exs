defmodule GSMLG.Web.Hologram.LookupPagesTest do
  use ExUnit.Case, async: true

  alias GSMLG.Web.Hologram.Pages.{Index, IpGeo, MacManufacturer, Svg2React, Whois}
  alias Hologram.{Component, Server}

  test "index and lookup pages retain their public routes" do
    for {page, route} <- [
          {Index, "/toolbox"},
          {IpGeo, "/toolbox/ip_geo"},
          {Whois, "/toolbox/whois"},
          {MacManufacturer, "/toolbox/mac_manufacturer"},
          {Svg2React, "/toolbox/svg2react"}
        ] do
      assert Code.ensure_loaded?(page)
      assert page.__route__() == route
    end
  end

  test "lookup submission clears stale results and queues only the public lookup" do
    component = %Component{state: %{loading: false, result: %{old: true}, error: "old"}}

    assert %{state: %{loading: true, result: nil, error: nil}, next_command: command} =
             MacManufacturer.action(
               :lookup,
               %{event: %{"mac" => " 00:00:0A:BB:28:FC "}},
               component
             )

    assert %{name: :lookup, params: %{mac: "00:00:0A:BB:28:FC"}} = command
  end

  test "lookup actions accept string-keyed fields emitted by Hologram form submission" do
    for {page, fields, expected} <- [
          {IpGeo, %{"ip" => " 8.8.8.8 "}, %{ip: "8.8.8.8"}},
          {Whois, %{"look_for" => " example.com ", "protocol" => "rdap"},
           %{look_for: "example.com", protocol: "rdap"}},
          {Svg2React, %{"code" => "<svg />"}, %{code: "<svg />"}}
        ] do
      assert %{next_command: %{name: :lookup, params: ^expected}} =
               page.action(:lookup, %{event: fields}, %Component{})
    end
  end

  test "WHOIS protocol selection survives loading and result renders" do
    component = %Component{state: %{protocol: "whois"}}

    assert %{state: %{protocol: "rdap"}} =
             component =
             Whois.action(
               :protocol_changed,
               %{event: %{value: true}, protocol: "rdap"},
               component
             )

    assert %{state: %{protocol: "rdap", loading: true}} =
             component =
             Whois.action(
               :lookup,
               %{event: %{"look_for" => "example.com", "protocol" => "rdap"}},
               component
             )

    assert %{state: %{protocol: "rdap", loading: false}} =
             Whois.action(:loaded, %{result: %{protocol: "rdap", data: %{}}}, component)
  end

  test "commands reject invalid input without accessing backend services" do
    for {page, params} <- [
          {IpGeo, %{ip: "not an ip"}},
          {IpGeo, %{ip: %{unexpected: "shape"}}},
          {MacManufacturer, %{mac: "invalid"}},
          {Whois, %{look_for: "example.com\r\ninjected", protocol: "whois"}},
          {Whois, %{look_for: "example.com", protocol: "unknown"}},
          {Svg2React, %{code: ""}},
          {Svg2React, %{code: %{unexpected: "shape"}}}
        ] do
      assert %{next_action: %{name: :failed, params: %{error: :invalid_input}}} =
               page.command(:lookup, params, %Server{})
    end
  end

  test "lookup failures reset loading and use translated invalid-input text" do
    component = %Component{
      state: %{loading: true, result: nil, error: nil, text: %{invalid_input: "Invalid value"}}
    }

    assert %{state: %{loading: false, error: "Invalid value"}} =
             Whois.action(:failed, %{error: :invalid_input}, component)
  end

  test "MAC result action preserves both vendor names" do
    result = %{short: "OmronTat", full: "Omron Tateisi Electronics Co."}
    component = %Component{state: %{loading: true, result: nil, error: nil}}

    assert %{state: %{loading: false, result: ^result, error: nil}} =
             MacManufacturer.action(:loaded, %{result: result}, component)
  end

  test "MAC commands use the actual manufacturer database" do
    assert %{next_action: %{name: :loaded, params: %{result: result}}} =
             MacManufacturer.command(:lookup, %{mac: "00:00:0A:BB:28:FC"}, %Server{})

    assert result == %{short: "OmronTat", full: "Omron Tateisi Electronics Co."}

    assert %{next_action: %{name: :failed, params: %{error: :unknown}}} =
             MacManufacturer.command(:lookup, %{mac: "FF:FF:FF:FF:FF:FF"}, %Server{})
  end

  test "RDAP display retains registration, DNSSEC, registrar and nested abuse information" do
    data = %{
      "ldhName" => "example.com",
      "status" => ["active"],
      "events" => [%{"eventAction" => "registration", "eventDate" => "2020-01-01"}],
      "nameservers" => [%{"ldhName" => "ns1.example.com"}],
      "secureDNS" => %{"delegationSigned" => true, "dsData" => [%{"digest" => "ABC"}]},
      "entities" => [
        %{
          "handle" => "registrar-1",
          "roles" => ["registrar"],
          "vcardArray" => ["vcard", [["fn", %{}, "text", "Example Registrar"]]],
          "entities" => [
            %{
              "roles" => ["abuse"],
              "vcardArray" => ["vcard", [["email", %{}, "text", "abuse@example.com"]]]
            }
          ]
        }
      ],
      "links" => [
        %{"href" => "https://rdap.example.com/domain/example.com", "rel" => "self"},
        %{"href" => "javascript:alert(1)", "rel" => "self"},
        %{"href" => "//untrusted.example", "rel" => "self"}
      ]
    }

    assert %{
             name: "example.com",
             status: ["active"],
             events: [%{action: "registration", date: "2020-01-01"}],
             nameservers: ["ns1.example.com"],
             dnssec: %{signed: true, records: [%{digest: "ABC"}]},
             entities: [%{name: "Example Registrar", abuse: ["abuse@example.com"]}],
             links: ["https://rdap.example.com/domain/example.com"]
           } = Whois.rdap_view(data)
  end

  test "SVG conversion preserves the existing controller option contract" do
    assert %{"code" => "<svg />", "options" => options} = Svg2React.conversion_data("<svg />")
    assert options["icon"] == true
    assert options["native"] == false
    assert options["ref"] == true
    assert options["typescript"] == false
    assert options["expandProps"] == "end"
    assert options["prettierConfig"] == %{"semi" => false}

    assert options["svgoConfig"] == %{
             "plugins" => [
               %{
                 "name" => "preset-default",
                 "params" => %{"overrides" => %{"removeTitle" => false}}
               }
             ]
           }
  end

  test "SVG conversion attempts return a temporary unavailable error" do
    error = GSMLG.SVG2React.unavailable_message()

    assert GSMLG.SVG2React.convert(Svg2React.conversion_data("<svg />")) == {:error, error}

    assert %{next_action: %{name: :failed, params: %{error: ^error}}} =
             Svg2React.command(:lookup, %{code: "<svg />"}, %Server{})
  end

  test "malformed optional RDAP values cannot crash result normalization" do
    assert %{name: "", events: [], nameservers: [], dnssec: nil, entities: [], links: []} =
             Whois.rdap_view(nil)

    assert %{
             name: "example.com",
             status: ["active"],
             events: [%{action: nil, date: nil}],
             nameservers: [],
             dnssec: %{signed: false, records: [%{digest: nil}]},
             entities: [%{name: "", roles: "registrar", public_ids: [], abuse: []}],
             links: []
           } =
             Whois.rdap_view(%{
               "ldhName" => %{},
               "handle" => "example.com",
               "status" => ["active", %{}],
               "events" => [nil, "invalid", %{"eventAction" => %{}, "eventDate" => []}],
               "nameservers" => [nil, %{"ldhName" => []}],
               "secureDNS" => %{"dsData" => [false, %{"digest" => %{}}]},
               "entities" => [
                 nil,
                 %{
                   "handle" => %{},
                   "roles" => ["registrar", %{}],
                   "publicIds" => [false],
                   "entities" => [false]
                 }
               ],
               "links" => [false, %{"rel" => "self", "href" => %{}}]
             })
  end
end
