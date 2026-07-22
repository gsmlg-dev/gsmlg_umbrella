defmodule GSMLG.ProxyRules.CompilerTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Compiler, Diagnostic, Output, Snapshot}

  @compiled_at ~U[2026-07-23 01:02:03.987654Z]

  test "output derives exact immutable content metadata including empty content" do
    output = Output.new("example.com\n", @compiled_at)

    assert %Output{
             body: "example.com\n",
             sha256: "391196688aa55d3321deffa736f8d103b4813470952b748e9c2c9deb17fa60f5",
             etag: "\"sha256-391196688aa55d3321deffa736f8d103b4813470952b748e9c2c9deb17fa60f5\"",
             last_modified: ~U[2026-07-23 01:02:03Z],
             content_type: "text/plain; charset=utf-8",
             content_length: 12
           } = output

    empty = Output.new("", @compiled_at)
    assert empty.content_length == 0
    assert empty.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert empty.last_modified == ~U[2026-07-23 01:02:03Z]
  end

  test "compiles both lists independently and records exact folding statistics" do
    input = %{
      remote:
        Base.encode64(
          "||example.com^\n||api.example.com^\n||example.com^\n@@||direct.example.com^\n@@||example.com^\n"
        ),
      local_proxy: "api.example.com\nother.test\nother.test\n",
      local_direct: "internal.example.com\nchild.internal.example.com\n"
    }

    assert {:ok, %Snapshot{} = snapshot} =
             Compiler.compile(input,
               generation: 7,
               compiled_at: @compiled_at,
               sample_limit: 10
             )

    assert snapshot.generation == 7
    assert snapshot.compiled_at == ~U[2026-07-23 01:02:03Z]
    assert snapshot.readiness == :ready
    assert snapshot.last_error == nil
    assert snapshot.statistics.conflict_count == 1
    assert snapshot.statistics.duplicate_count == 3
    assert snapshot.statistics.collapsed_count == 4
    assert snapshot.statistics.proxy_rule_count == 2
    assert snapshot.statistics.direct_rule_count == 1

    assert snapshot.rendered_outputs.proxy.raw.body == "example.com\nother.test\n"

    assert snapshot.rendered_outputs.direct.raw.body == "example.com\n"

    assert %{
             proxy: %{raw: %Output{}, squid: %Output{}, clash: %Output{}},
             direct: %{raw: %Output{}, squid: %Output{}, clash: %Output{}}
           } = snapshot.rendered_outputs

    assert snapshot.rendered_outputs.proxy.squid.body == ".example.com\n.other.test\n"

    assert snapshot.rendered_outputs.proxy.clash.body ==
             "DOMAIN-SUFFIX,example.com\nDOMAIN-SUFFIX,other.test\n"

    assert snapshot.rendered_outputs.direct.squid.body == ".example.com\n"

    assert snapshot.rendered_outputs.direct.clash.body == "DOMAIN-SUFFIX,example.com\n"
  end

  test "counts exact cross-list conflicts before hierarchy folding" do
    input = %{
      remote: Base.encode64("||example.com^\n||a.example.com^\n@@||a.example.com^\n"),
      local_proxy: "",
      local_direct: ""
    }

    assert {:ok, snapshot} =
             Compiler.compile(input,
               generation: 8,
               compiled_at: @compiled_at,
               sample_limit: 1
             )

    assert snapshot.rendered_outputs.proxy.raw.body == "example.com\n"
    assert snapshot.rendered_outputs.direct.raw.body == "a.example.com\n"
    assert snapshot.statistics.conflict_count == 1
  end

  test "metadata recursively omits artifact bodies and retains validators" do
    assert {:ok, snapshot} =
             Compiler.compile(
               %{remote: Base.encode64("||example.com^\n"), local_proxy: "", local_direct: ""},
               generation: 3,
               compiled_at: @compiled_at,
               sample_limit: 1
             )

    metadata = Snapshot.metadata(snapshot)

    assert metadata.generation == 3
    assert metadata.readiness == :ready

    assert metadata.rendered_outputs.proxy.raw.sha256 ==
             snapshot.rendered_outputs.proxy.raw.sha256

    assert metadata.rendered_outputs.proxy.raw.content_length == 12
    refute Map.has_key?(metadata.rendered_outputs.proxy.raw, :body)
    refute inspect(metadata) =~ "example.com"
  end

  test "returns systemic diagnostics for invalid source shape and remote decoding" do
    assert {:error,
            [%Diagnostic{kind: :systemic, source: :local_proxy, reason: :systemic_failure}]} =
             Compiler.compile(
               %{remote: Base.encode64("||example.com^"), local_proxy: nil, local_direct: ""},
               generation: 1,
               sample_limit: 1
             )

    assert {:error, [%Diagnostic{kind: :systemic, source: :gfwlist, reason: :invalid_base64}]} =
             Compiler.compile(
               %{remote: "not base64", local_proxy: "", local_direct: ""},
               generation: 1,
               sample_limit: 1
             )

    assert {:error, [%Diagnostic{kind: :systemic, source: :gfwlist, reason: :invalid_utf8}]} =
             Compiler.compile(
               %{remote: Base.encode64(<<255>>), local_proxy: "", local_direct: ""},
               generation: 1,
               sample_limit: 1
             )
  end

  test "returns bounded systemic diagnostics for invalid local UTF-8" do
    valid_remote = Base.encode64("||example.com^\n")

    assert {:error,
            [
              %Diagnostic{
                kind: :systemic,
                source: :local_proxy,
                location: :system,
                reason: :invalid_utf8,
                sample: nil
              }
            ]} =
             Compiler.compile(
               %{remote: valid_remote, local_proxy: <<255>>, local_direct: ""},
               generation: 1,
               sample_limit: 1
             )

    assert {:error,
            [
              %Diagnostic{
                kind: :systemic,
                source: :local_direct,
                location: :system,
                reason: :invalid_utf8,
                sample: nil
              }
            ]} =
             Compiler.compile(
               %{remote: valid_remote, local_proxy: "", local_direct: <<255>>},
               generation: 1,
               sample_limit: 1
             )
  end

  test "rejects a forged DateTime with bounded systemic diagnostics" do
    malformed = %{@compiled_at | month: 13}

    assert {:error,
            [
              %Diagnostic{
                kind: :systemic,
                source: :gfwlist,
                location: :system,
                reason: :systemic_failure,
                sample: nil
              }
            ]} =
             Compiler.compile(
               %{remote: Base.encode64("||example.com^\n"), local_proxy: "", local_direct: ""},
               generation: 1,
               compiled_at: malformed,
               sample_limit: 1
             )
  end

  test "caps combined diagnostic samples while preserving every source count" do
    assert {:ok, snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("unsupported rule\n"),
                 local_proxy: "bad_proxy.example\n",
                 local_direct: "bad_direct.example\n"
               },
               generation: 1,
               compiled_at: @compiled_at,
               sample_limit: 1
             )

    assert [_one_sample] = snapshot.diagnostics
    assert snapshot.statistics.sources.gfwlist.unsupported == 1
    assert snapshot.statistics.sources.local_proxy.invalid == 1
    assert snapshot.statistics.sources.local_direct.invalid == 1
  end
end
