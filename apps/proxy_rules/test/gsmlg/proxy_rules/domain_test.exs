defmodule GSMLG.ProxyRules.DomainTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Diagnostic, Domain, Rule}

  describe "normalize/1" do
    test "trims, removes suffix dots, lowercases, and reverses labels" do
      assert {:ok, %Domain{name: "example.com", reversed_labels: ["com", "example"]}} =
               Domain.normalize(" .Example.COM. ")
    end

    test "extracts a domain from a supported URL" do
      assert {:ok, %Domain{name: "example.com"}} =
               Domain.normalize("https://Example.com:443")
    end

    test "converts Unicode domains to IDNA ASCII" do
      assert {:ok, %Domain{name: "xn--bcher-kva.example"}} =
               Domain.normalize("bücher.example")
    end

    test "preserves IDNA validation for ASCII labels with reserved hyphen forms" do
      for domain <- ["xn--a.example", "ab--cd.example"] do
        assert {:error, :invalid_idna} = Domain.normalize(domain)
      end
    end

    test "accepts a bare domain and a supported URL with a root path" do
      assert {:ok, %Domain{name: "example.com"}} = Domain.normalize("example.com")
      assert {:ok, %Domain{name: "example.com"}} = Domain.normalize("http://example.com/")
    end

    test "rejects IP literals" do
      assert {:error, _reason} = Domain.normalize("192.0.2.1")
      assert {:error, _reason} = Domain.normalize("https://[2001:db8::1]/")
    end

    test "rejects wildcard, underscore, edge-hyphen, and empty labels" do
      invalid_domains = [
        "*.example.com",
        "under_score.example",
        "-edge.example",
        "edge-.example",
        "empty..example"
      ]

      for domain <- invalid_domains do
        assert {:error, _reason} = Domain.normalize(domain)
      end
    end

    test "rejects labels longer than 63 bytes" do
      domain = String.duplicate("a", 64) <> ".example"

      assert {:error, _reason} = Domain.normalize(domain)
    end

    test "rejects domains longer than 253 bytes" do
      domain = List.duplicate(String.duplicate("a", 63), 4) |> Enum.join(".")

      assert byte_size(domain) > 253
      assert {:error, _reason} = Domain.normalize(domain)
    end

    test "rejects unsupported URL schemes" do
      assert {:error, :unsupported_scheme} = Domain.normalize("ftp://example.com")
    end

    test "rejects URLs with userinfo, non-root paths, queries, or fragments" do
      invalid_urls = [
        "https://user@example.com/",
        "https://example.com:not-a-port",
        "https://example.com/path",
        "https://example.com/?query=value",
        "https://example.com/#fragment"
      ]

      for url <- invalid_urls do
        assert {:error, :invalid_url} = Domain.normalize(url)
      end
    end

    test "rejects an empty value" do
      assert {:error, _reason} = Domain.normalize("  ")
    end

    test "rejects empty hosts and malformed URL ports" do
      for url <- ["http://", "http://example.com:", "http://example.com:65536"] do
        assert {:error, :invalid_url} = Domain.normalize(url)
      end
    end

    test "removes exactly one optional leading and trailing dot" do
      assert {:ok, %Domain{name: "example.com"}} = Domain.normalize(".example.com.")
      assert {:error, _reason} = Domain.normalize("..example.com")
      assert {:error, _reason} = Domain.normalize("example.com..")
    end
  end

  describe "published types" do
    test "keeps normalization errors and parser values finite" do
      domain_reasons = type_definition!(Domain, :error_reason)
      rule_source = type_definition!(Rule, :source)
      diagnostic_source = type_definition!(Diagnostic, :source)
      diagnostic_reason = type_definition!(Diagnostic, :reason)

      assert literal_atoms(domain_reasons) ==
               MapSet.new([
                 :invalid_value,
                 :empty_domain,
                 :invalid_url,
                 :unsupported_scheme,
                 :invalid_idna,
                 :ip_literal,
                 :domain_too_long,
                 :empty_label,
                 :label_too_long,
                 :invalid_label
               ])

      assert literal_atoms(rule_source) ==
               MapSet.new([:gfwlist, :local_proxy, :local_direct])

      refute contains_unbounded_atom?(domain_reasons)
      refute contains_unbounded_atom?(rule_source)
      refute contains_unbounded_atom?(diagnostic_source)
      refute contains_unbounded_atom?(diagnostic_reason)

      assert contains_type_reference?(normalize_spec!(), :error_reason)
      assert contains_remote_type_reference?(diagnostic_source, Rule, :source)
      assert contains_remote_type_reference?(diagnostic_reason, Domain, :error_reason)
    end
  end

  defp type_definition!(module, name) do
    assert {:ok, types} = Code.Typespec.fetch_types(module)

    assert {:type, {^name, definition, []}} =
             Enum.find(types, fn
               {:type, {^name, _definition, []}} -> true
               _type -> false
             end)

    definition
  end

  defp normalize_spec! do
    assert {:ok, specs} = Code.Typespec.fetch_specs(Domain)
    assert {{:normalize, 1}, [spec]} = Enum.find(specs, &(elem(&1, 0) == {:normalize, 1}))
    spec
  end

  defp literal_atoms(term) do
    Enum.reduce(nodes(term), MapSet.new(), fn
      {:atom, _line, value}, atoms -> MapSet.put(atoms, value)
      _node, atoms -> atoms
    end)
  end

  defp contains_unbounded_atom?(term) do
    Enum.any?(nodes(term), &match?({:type, _line, :atom, []}, &1))
  end

  defp contains_type_reference?(term, type) do
    Enum.any?(nodes(term), &match?({:user_type, _line, ^type, []}, &1))
  end

  defp contains_remote_type_reference?(term, module, type) do
    Enum.any?(nodes(term), fn
      {:remote_type, _line, [{:atom, _module_line, ^module}, {:atom, _type_line, ^type}, []]} ->
        true

      _node ->
        false
    end)
  end

  defp nodes(term) when is_tuple(term) do
    [term | term |> Tuple.to_list() |> Enum.flat_map(&nodes/1)]
  end

  defp nodes(terms) when is_list(terms), do: Enum.flat_map(terms, &nodes/1)
  defp nodes(_term), do: []
end
