defmodule GSMLG.ProxyRules.DomainPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GSMLG.ProxyRules.Domain

  property "normalization is idempotent for accepted candidates" do
    check all(candidate <- domain_candidate()) do
      case Domain.normalize(candidate) do
        {:ok, domain} -> assert Domain.normalize(domain.name) == {:ok, domain}
        {:error, _reason} -> :ok
      end
    end
  end

  defp domain_candidate do
    StreamData.one_of([valid_domain_candidate(), invalid_domain_candidate()])
  end

  defp valid_domain_candidate do
    gen all(
          labels <- StreamData.list_of(valid_label(), min_length: 2, max_length: 4),
          form <- StreamData.member_of([:bare, :http, :https])
        ) do
      domain = Enum.join(labels, ".")

      case form do
        :bare -> domain
        :http -> "http://#{domain}/"
        :https -> "https://#{domain}:443"
      end
    end
  end

  defp valid_label do
    StreamData.list_of(
      StreamData.member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)),
      min_length: 1,
      max_length: 20
    )
    |> StreamData.map(&List.to_string/1)
  end

  defp invalid_domain_candidate do
    gen all(
          label <- valid_label(),
          invalid_form <-
            StreamData.member_of([
              :wildcard,
              :underscore,
              :leading_hyphen,
              :trailing_hyphen,
              :empty_label,
              :path,
              :query,
              :fragment
            ])
        ) do
      case invalid_form do
        :wildcard -> "*.#{label}.example"
        :underscore -> "#{label}_value.example"
        :leading_hyphen -> "-#{label}.example"
        :trailing_hyphen -> "#{label}-.example"
        :empty_label -> "#{label}..example"
        :path -> "https://#{label}.example/path"
        :query -> "https://#{label}.example/?query=value"
        :fragment -> "https://#{label}.example/#fragment"
      end
    end
  end
end
