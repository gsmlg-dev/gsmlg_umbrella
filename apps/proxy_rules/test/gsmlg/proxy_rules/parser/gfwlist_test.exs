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

  @tag timeout: 30_000
  test "the attributed official fixture is valid" do
    fixture = read_fixture("official.txt")

    assert {:ok, %ParseResult{counts: %{accepted: accepted}}, _metadata} =
             GFWList.parse(fixture, 20)

    assert accepted > 1_000
  end

  defp read_fixture(name) do
    Path.join([__DIR__, "../../../fixtures/gfwlist", name])
    |> File.read!()
  end
end
