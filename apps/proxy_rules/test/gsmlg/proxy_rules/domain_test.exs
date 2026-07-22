defmodule GSMLG.ProxyRules.DomainTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Domain

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
      assert {:error, _reason} = Domain.normalize("ftp://example.com")
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
        assert {:error, _reason} = Domain.normalize(url)
      end
    end

    test "rejects an empty value" do
      assert {:error, _reason} = Domain.normalize("  ")
    end
  end
end
