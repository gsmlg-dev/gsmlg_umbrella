defmodule GSMLG.ProxyRules.Parser.LocalTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Diagnostic, Domain, ParseResult, Rule}
  alias GSMLG.ProxyRules.Parser.Local

  test "parses comments and keeps bounded invalid diagnostics" do
    text = "# comment\n.Example.com.\n! ignored\nbad_label.example\napi.example.com\n"

    assert %ParseResult{
             rules: [
               %Rule{
                 domain: %Domain{name: "example.com"},
                 action: :proxy,
                 source: :local_proxy,
                 location: 2,
                 match: :suffix
               },
               %Rule{
                 domain: %Domain{name: "api.example.com"},
                 action: :proxy,
                 source: :local_proxy,
                 location: 5,
                 match: :suffix
               }
             ],
             counts: %{accepted: 2, invalid: 1, unsupported: 0},
             diagnostics: [
               %Diagnostic{
                 kind: :invalid,
                 source: :local_proxy,
                 location: 4,
                 reason: :invalid_idna,
                 sample: "bad_label.example"
               }
             ]
           } = Local.parse(text, :proxy, :local_proxy, 1)
  end

  test "splits Unicode line breaks and preserves accepted order, line numbers, and raw samples" do
    text =
      " first.example\r\n# note\u2028 bad_label.example \u2029 second.example \u0085third.example"

    result = Local.parse(text, :direct, :local_direct, 2)

    assert Enum.map(result.rules, &{&1.domain.name, &1.location, &1.action, &1.source}) == [
             {"first.example", 1, :direct, :local_direct},
             {"second.example", 4, :direct, :local_direct},
             {"third.example", 5, :direct, :local_direct}
           ]

    assert result.counts == %{accepted: 3, invalid: 1, unsupported: 0}

    assert [%Diagnostic{location: 3, sample: " bad_label.example "}] = result.diagnostics
  end

  test "keeps complete invalid counts after diagnostic samples are full" do
    text = "bad_one.example\nbad_two.example\nbad_three.example\nvalid.example"

    assert %ParseResult{
             counts: %{accepted: 1, invalid: 3, unsupported: 0},
             diagnostics: [%Diagnostic{location: 1, sample: "bad_one.example"}]
           } = Local.parse(text, :proxy, :local_proxy, 1)
  end

  test "a zero diagnostic limit retains no samples while preserving full counts" do
    assert %ParseResult{
             rules: [%Rule{domain: %Domain{name: "valid.example"}}],
             counts: %{accepted: 1, invalid: 2, unsupported: 0},
             diagnostics: []
           } =
             Local.parse(
               "bad_one.example\nbad_two.example\nvalid.example",
               :direct,
               :local_direct,
               0
             )
  end

  test "bounds multibyte diagnostic samples to valid UTF-8 within 512 bytes" do
    invalid = String.duplicate("界", 300) <> "_bad"

    assert %ParseResult{
             counts: %{accepted: 0, invalid: 1, unsupported: 0},
             diagnostics: [%Diagnostic{sample: sample}]
           } = Local.parse(invalid, :proxy, :local_proxy, 1)

    assert byte_size(sample) <= 512
    assert String.valid?(sample)
    assert String.ends_with?(sample, "...[truncated]")
    refute sample == invalid
  end

  test "ignores whitespace-only and indented comment lines" do
    result = Local.parse(" \t\n  # comment\n\t! comment\nexample.com", :proxy, :local_proxy, 1)

    assert %ParseResult{
             rules: [%Rule{domain: %Domain{name: "example.com"}, location: 4}],
             counts: %{accepted: 1, invalid: 0, unsupported: 0},
             diagnostics: []
           } = result
  end
end
