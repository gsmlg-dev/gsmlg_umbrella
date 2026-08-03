defmodule GSMLG.ProxyRules.LocalProxyBatch do
  @moduledoc """
  Validates and prepares bare domains for appending to the local proxy source.
  """

  alias GSMLG.ProxyRules.Domain

  @type rejection_reason ::
          :leading_dot_not_allowed
          | :comment_not_allowed
          | :url_not_allowed
          | :path_not_allowed
          | :wildcard_not_allowed
          | Domain.error_reason()
  @type line_error :: %{line: pos_integer(), reason: rejection_reason()}
  @type result :: %{
          content: binary(),
          added_domains: [binary()],
          added_count: non_neg_integer(),
          duplicate_count: non_neg_integer()
        }
  @type error_reason ::
          :empty_batch
          | :body_too_large
          | {:invalid_batch, [line_error()]}

  @doc """
  Validates a textarea batch and prepares the complete local proxy source body.
  """
  @spec prepare(binary(), binary(), keyword()) ::
          {:ok, result()} | {:error, error_reason()}
  def prepare(existing, input, options)
      when is_binary(existing) and is_binary(input) and is_list(options) do
    max_bytes = Keyword.fetch!(options, :max_bytes)

    with {:ok, submitted} <- validate_lines(input) do
      {added_domains, _seen, duplicate_count} =
        Enum.reduce(submitted, {[], existing_domains(existing), 0}, fn domain,
                                                                       {added, seen, duplicates} ->
          if MapSet.member?(seen, domain) do
            {added, seen, duplicates + 1}
          else
            {[domain | added], MapSet.put(seen, domain), duplicates}
          end
        end)

      added_domains = Enum.reverse(added_domains)
      content = append_domains(existing, added_domains)

      if byte_size(content) <= max_bytes do
        {:ok,
         %{
           content: content,
           added_domains: added_domains,
           added_count: length(added_domains),
           duplicate_count: duplicate_count
         }}
      else
        {:error, :body_too_large}
      end
    end
  end

  defp validate_lines(input) do
    {domains, errors} =
      input
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {raw_value, line}, {domains, errors} ->
        value = String.trim(raw_value)

        case validate_line(value) do
          :blank -> {domains, errors}
          {:ok, domain} -> {[domain | domains], errors}
          {:error, reason} -> {domains, [%{line: line, reason: reason} | errors]}
        end
      end)

    case {domains, errors} do
      {[], []} -> {:error, :empty_batch}
      {_domains, []} -> {:ok, Enum.reverse(domains)}
      {_domains, errors} -> {:error, {:invalid_batch, Enum.reverse(errors)}}
    end
  end

  defp validate_line(""), do: :blank

  defp validate_line(value) do
    cond do
      String.starts_with?(value, ".") ->
        {:error, :leading_dot_not_allowed}

      String.starts_with?(value, ["#", "!"]) ->
        {:error, :comment_not_allowed}

      String.contains?(value, "://") ->
        {:error, :url_not_allowed}

      String.contains?(value, "*") ->
        {:error, :wildcard_not_allowed}

      String.contains?(value, "/") ->
        {:error, :path_not_allowed}

      ip_literal?(value) ->
        {:error, :ip_literal}

      true ->
        case Domain.normalize(value) do
          {:ok, domain} -> {:ok, domain.name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ip_literal?(value) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(value)))
  end

  defp existing_domains(existing) do
    existing
    |> String.split(~r/\r\n|\n|\r/)
    |> Enum.reduce(MapSet.new(), fn value, domains ->
      value = String.trim(value)

      cond do
        value == "" or String.starts_with?(value, ["#", "!"]) ->
          domains

        true ->
          case Domain.normalize(value) do
            {:ok, domain} -> MapSet.put(domains, domain.name)
            {:error, _reason} -> domains
          end
      end
    end)
  end

  defp append_domains(existing, []), do: existing

  defp append_domains(existing, domains) do
    separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
    existing <> separator <> Enum.map_join(domains, "", &(&1 <> "\n"))
  end
end
