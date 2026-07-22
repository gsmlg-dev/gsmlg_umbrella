defmodule GSMLG.ProxyRules.Parser.GFWListTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Diagnostic, ParseResult}
  alias GSMLG.ProxyRules.Parser.GFWList

  test "decodes whitespace-tolerant Base64 and classifies safe rules" do
    encoded =
      Base.encode64("[Adblock Plus 2.0]\n! comment\n||example.com^\n@@||direct.example.com^\n")

    spaced = encoded |> String.graphemes() |> Enum.chunk_every(16) |> Enum.join("\n")

    assert {:ok, result, metadata} = GFWList.parse(spaced, 10)

    assert Enum.map(result.rules, &{&1.action, &1.domain.name}) == [
             proxy: "example.com",
             direct: "direct.example.com"
           ]

    assert metadata.decoded_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert result.counts == %{accepted: 2, invalid: 0, unsupported: 0}
  end

  test "decodes the synthetic fixture with every supported and rejected class" do
    assert {:ok, result, _metadata} = GFWList.parse(read_fixture("supported.txt"), 20)

    assert Enum.map(result.rules, &{&1.action, &1.domain.name, &1.location}) == [
             {:proxy, "proxy.example", 4},
             {:direct, "direct.example", 5},
             {:proxy, "plain.example", 6},
             {:proxy, "whole-host.example", 7},
             {:proxy, "xn--bcher-kva.example", 13}
           ]

    assert result.counts == %{accepted: 5, invalid: 1, unsupported: 4}

    assert Enum.map(result.diagnostics, &{&1.kind, &1.reason, &1.location, &1.sample}) == [
             {:unsupported, :path_specific, 8, "||path.example/path"},
             {:unsupported, :regular_expression, 9, "/path\\\\.example/"},
             {:unsupported, :modifier, 10, "||modifier.example^$script"},
             {:unsupported, :wildcard, 11, "||*.wildcard.example^"},
             {:invalid, :invalid_idna, 12, "||bad_domain.example^"}
           ]
  end

  test "never broadens path, query, fragment, regex, modifier, or wildcard rules" do
    source =
      Enum.join(
        [
          "||example.com/path",
          "https://example.com/?query=yes",
          "https://example.com/#fragment",
          "/example\\.com/",
          "||example.com^$script",
          "||*.example.com^"
        ],
        "\n"
      )

    assert {:ok,
            %ParseResult{
              rules: [],
              counts: %{accepted: 0, invalid: 0, unsupported: 6},
              diagnostics: diagnostics
            }, _metadata} = GFWList.parse(Base.encode64(source), 10)

    assert Enum.map(diagnostics, & &1.reason) == [
             :path_specific,
             :path_specific,
             :path_specific,
             :regular_expression,
             :modifier,
             :wildcard
           ]
  end

  test "distinguishes invalid Base64 and decoded invalid UTF-8 without crashing" do
    assert {:error, :invalid_base64} = GFWList.decode("not base64")
    assert {:error, :invalid_base64} = GFWList.decode(<<255, 0, 1>>)
    assert {:error, :invalid_utf8} = GFWList.decode(Base.encode64(<<255>>))
  end

  test "preserves complete counts while globally bounding diagnostic samples" do
    source = "||bad_domain.example^\n||path.example/path\n||also_bad.example^\n"

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 1)
    assert result.counts == %{accepted: 0, invalid: 2, unsupported: 1}

    assert [
             %Diagnostic{
               kind: :invalid,
               source: :gfwlist,
               location: 1,
               reason: :invalid_idna,
               sample: "||bad_domain.example^"
             }
           ] = result.diagnostics

    assert {:ok, zero_sample_result, _metadata} = GFWList.parse(Base.encode64(source), 0)
    assert zero_sample_result.counts == result.counts
    assert zero_sample_result.diagnostics == []
  end

  test "classifies malformed candidates as invalid and ambiguous syntax as unsupported" do
    source = "@@||bad_domain.example^\n@@nonsense\nftp://example.com/\n"

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 10)
    assert result.counts == %{accepted: 0, invalid: 1, unsupported: 2}

    assert Enum.map(result.diagnostics, &{&1.kind, &1.reason}) == [
             {:invalid, :invalid_idna},
             {:unsupported, :ambiguous_rule},
             {:unsupported, :ambiguous_rule}
           ]
  end

  test "rejects repeated terminal separators without broadening proxy or exception rules" do
    source = "||proxy.example^^\n@@||direct.example^^\n"

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 10)
    assert result.rules == []
    assert result.counts == %{accepted: 0, invalid: 0, unsupported: 2}

    assert Enum.map(result.diagnostics, &{&1.kind, &1.reason, &1.location}) == [
             {:unsupported, :ambiguous_rule, 1},
             {:unsupported, :ambiguous_rule, 2}
           ]
  end

  test "accepts whole-host URLs without end anchors and rejects every trailing pipe" do
    valid = "http://plain.example/\n|https://start.example/\n"

    assert {:ok, valid_result, _metadata} = GFWList.parse(Base.encode64(valid), 10)

    assert Enum.map(valid_result.rules, & &1.domain.name) == [
             "plain.example",
             "start.example"
           ]

    assert valid_result.counts == %{accepted: 2, invalid: 0, unsupported: 0}

    malformed =
      "http://root-only.example/|\n|https://exact.example/|\n|http://example.com||\nhttp://example.com||\n|https://example.com|||\nhttp://example.com|extra\n"

    assert {:ok, malformed_result, _metadata} = GFWList.parse(Base.encode64(malformed), 10)
    assert malformed_result.rules == []
    assert malformed_result.counts == %{accepted: 0, invalid: 0, unsupported: 6}

    assert Enum.map(malformed_result.diagnostics, &{&1.kind, &1.reason, &1.location}) == [
             {:unsupported, :ambiguous_rule, 1},
             {:unsupported, :ambiguous_rule, 2},
             {:unsupported, :ambiguous_rule, 3},
             {:unsupported, :ambiguous_rule, 4},
             {:unsupported, :ambiguous_rule, 5},
             {:unsupported, :ambiguous_rule, 6}
           ]
  end

  test "rejects explicitly specified URL ports before domain extraction" do
    source =
      "http://no-port.example/\nhttp://http-default.example:80/\nhttps://https-default.example:443/\nhttps://alternate.example:8443/\nhttp://zero.example:0/\n"

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 10)
    assert Enum.map(result.rules, & &1.domain.name) == ["no-port.example"]
    assert result.counts == %{accepted: 1, invalid: 0, unsupported: 4}

    assert Enum.map(result.diagnostics, &{&1.reason, &1.location}) == [
             {:ambiguous_rule, 2},
             {:ambiguous_rule, 3},
             {:ambiguous_rule, 4},
             {:ambiguous_rule, 5}
           ]
  end

  test "bounds retained diagnostic samples without breaking UTF-8 or aggregate counts" do
    oversized_ascii = String.duplicate("x", 700) <> " invalid rule"
    oversized_multibyte = "##" <> String.duplicate("界", 300)
    source = Enum.join([oversized_ascii, oversized_multibyte, "another invalid rule"], "\n")

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 10)
    assert result.counts == %{accepted: 0, invalid: 0, unsupported: 3}
    assert [ascii, multibyte, short] = Enum.map(result.diagnostics, & &1.sample)

    for sample <- [ascii, multibyte] do
      assert byte_size(sample) <= 512
      assert String.valid?(sample)
      assert String.ends_with?(sample, "...[truncated]")
    end

    refute ascii == oversized_ascii
    refute multibyte == oversized_multibyte
    assert short == "another invalid rule"
  end

  test "counts cosmetic filters and hash-prefixed syntax instead of ignoring them" do
    source =
      "! actual comment\n[Adblock Plus 2.0]\n##.advert\nexample.com##.advert\nexample.com#@#.advert\n# not an Adblock comment\n"

    assert {:ok, result, _metadata} = GFWList.parse(Base.encode64(source), 10)
    assert result.rules == []
    assert result.counts == %{accepted: 0, invalid: 0, unsupported: 4}

    assert Enum.map(result.diagnostics, &{&1.reason, &1.location, &1.sample}) == [
             {:ambiguous_rule, 3, "##.advert"},
             {:ambiguous_rule, 4, "example.com##.advert"},
             {:ambiguous_rule, 5, "example.com#@#.advert"},
             {:ambiguous_rule, 6, "# not an Adblock comment"}
           ]
  end

  @tag timeout: 30_000
  test "the attributed official fixture is valid" do
    fixture = read_fixture("official.txt")

    assert :crypto.hash(:sha256, fixture) |> Base.encode16(case: :lower) ==
             "22319f2a1dc096ef57af499f384138eae1842db1f85c28d60530b8abed805985"

    assert {:ok, %ParseResult{counts: %{accepted: accepted}}, _metadata} =
             GFWList.parse(fixture, 20)

    assert accepted > 1_000
  end

  defp read_fixture(name) do
    Path.join([__DIR__, "../../../fixtures/gfwlist", name])
    |> File.read!()
  end
end
