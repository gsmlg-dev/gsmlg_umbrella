defmodule GSMLG.ProxyRules.LocalProxyBatch do
  @moduledoc """
  Validates and prepares bare domains for appending to the local proxy source.

  Invalid batches retain up to 100 concrete line errors. When more errors are
  found, the result appends one `:too_many_errors` marker at the first omitted
  error line. Textarea input larger than `:max_bytes` is rejected before line
  validation, even when duplicate removal could make the final body smaller.
  """

  alias GSMLG.ProxyRules.Domain

  @max_line_errors 100
  @max_cache_entries 1_024

  @type rejection_reason ::
          :leading_dot_not_allowed
          | :comment_not_allowed
          | :url_not_allowed
          | :path_not_allowed
          | :wildcard_not_allowed
          | :invalid_utf8
          | :too_many_errors
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
  @type option :: {:max_bytes, non_neg_integer()}

  @doc """
  Validates a textarea batch and prepares the complete local proxy source body.
  """
  @spec prepare(binary(), binary(), [option()]) ::
          {:ok, result()} | {:error, error_reason()}
  def prepare(existing, input, options)
      when is_binary(existing) and is_binary(input) and is_list(options) do
    max_bytes = options |> Keyword.fetch!(:max_bytes) |> validate_max_bytes!()

    if byte_size(input) > max_bytes do
      {:error, :body_too_large}
    else
      input
      |> scan_input(1, initial_state(existing, max_bytes))
      |> build_result(existing, max_bytes)
    end
  end

  defp initial_state(existing, max_bytes) do
    existing_bytes = byte_size(existing)
    oversized? = existing_bytes > max_bytes

    %{
      mode: if(oversized?, do: :body_too_large, else: :valid),
      seen: if(oversized?, do: nil, else: existing_domains(existing)),
      cache: %{},
      added_domains: [],
      duplicate_count: 0,
      projected_bytes: if(oversized?, do: nil, else: existing_bytes),
      separator_bytes: separator_bytes(existing),
      max_bytes: max_bytes,
      nonblank?: false,
      errors: [],
      error_count: 0,
      first_omitted_error_line: nil
    }
  end

  defp validate_max_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes >= 0,
    do: max_bytes

  defp validate_max_bytes!(max_bytes) do
    raise ArgumentError,
          "expected :max_bytes to be a non-negative integer, got: #{inspect(max_bytes)}"
  end

  defp scan_input(input, line_number, state) do
    {raw_line, rest} = next_line(input)
    state = process_input_line(raw_line, line_number, state)

    cond do
      state.first_omitted_error_line != nil -> state
      rest == :done -> state
      true -> scan_input(rest, line_number + 1, state)
    end
  end

  defp process_input_line(raw_line, line_number, state) do
    {validation, cache} = validate_submitted_line(raw_line, state.cache)
    state = %{state | cache: cache}

    case validation do
      :blank -> state
      {:ok, domain} -> accept_domain(%{state | nonblank?: true}, domain)
      {:error, reason} -> retain_error(%{state | nonblank?: true}, line_number, reason)
    end
  end

  defp validate_submitted_line(raw_line, cache) do
    if String.valid?(raw_line) do
      value = String.trim(raw_line)

      case value do
        "" ->
          {:blank, cache}

        value ->
          case Map.fetch(cache, value) do
            {:ok, validation} -> {validation, cache}
            :error -> cache_validation(value, cache)
          end
      end
    else
      {{:error, :invalid_utf8}, cache}
    end
  end

  defp cache_validation(value, cache) do
    validation = validate_line(value)
    {validation, cache_entry(cache, value, validation)}
  end

  defp cache_entry(cache, key, value) when map_size(cache) < @max_cache_entries,
    do: Map.put(cache, key, value)

  defp cache_entry(cache, _key, _value), do: cache

  defp accept_domain(%{mode: :valid} = state, domain), do: add_domain(state, domain)
  defp accept_domain(state, _domain), do: state

  defp add_domain(state, domain) do
    if MapSet.member?(state.seen, domain) do
      %{state | duplicate_count: state.duplicate_count + 1}
    else
      projected_bytes =
        state.projected_bytes + byte_size(domain) + 1 +
          if(state.added_domains == [], do: state.separator_bytes, else: 0)

      if projected_bytes > state.max_bytes do
        discard_valid_result(state, :body_too_large)
      else
        %{
          state
          | seen: MapSet.put(state.seen, domain),
            added_domains: [domain | state.added_domains],
            projected_bytes: projected_bytes
        }
      end
    end
  end

  defp retain_error(%{error_count: error_count} = state, line, reason)
       when error_count < @max_line_errors do
    state = discard_valid_result(state, :invalid)

    %{
      state
      | errors: [%{line: line, reason: reason} | state.errors],
        error_count: error_count + 1
    }
  end

  defp retain_error(%{first_omitted_error_line: nil} = state, line, _reason),
    do: state |> discard_valid_result(:invalid) |> Map.put(:first_omitted_error_line, line)

  defp retain_error(state, _line, _reason), do: state

  defp discard_valid_result(state, mode) do
    %{
      state
      | mode: mode,
        seen: nil,
        added_domains: [],
        duplicate_count: 0,
        projected_bytes: nil
    }
  end

  defp build_result(%{errors: errors} = state, _existing, _max_bytes) when errors != [] do
    errors = format_errors(errors, state.first_omitted_error_line)
    {:error, {:invalid_batch, errors}}
  end

  defp build_result(%{nonblank?: false}, _existing, _max_bytes), do: {:error, :empty_batch}

  defp build_result(%{mode: :body_too_large}, _existing, _max_bytes),
    do: {:error, :body_too_large}

  defp build_result(state, existing, max_bytes) do
    added_domains = Enum.reverse(state.added_domains)
    content = append_domains(existing, added_domains)

    if byte_size(content) <= max_bytes do
      {:ok,
       %{
         content: content,
         added_domains: added_domains,
         added_count: length(added_domains),
         duplicate_count: state.duplicate_count
       }}
    else
      {:error, :body_too_large}
    end
  end

  defp format_errors(errors, nil), do: Enum.reverse(errors)

  defp format_errors(errors, first_omitted_error_line) do
    Enum.reverse(errors) ++ [%{line: first_omitted_error_line, reason: :too_many_errors}]
  end

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
    {domains, _cache} = scan_existing(existing, MapSet.new(), %{})
    domains
  end

  defp scan_existing(existing, domains, cache) do
    {raw_line, rest} = next_line(existing)
    {domains, cache} = include_existing_line(raw_line, domains, cache)

    case rest do
      :done -> {domains, cache}
      rest -> scan_existing(rest, domains, cache)
    end
  end

  defp include_existing_line(raw_line, domains, cache) do
    if String.valid?(raw_line) do
      value = String.trim(raw_line)

      cond do
        value == "" or String.starts_with?(value, ["#", "!"]) ->
          {domains, cache}

        true ->
          {normalization, cache} = cached_existing_normalization(value, cache)

          case normalization do
            {:ok, domain} -> {MapSet.put(domains, domain.name), cache}
            {:error, _reason} -> {domains, cache}
          end
      end
    else
      {domains, cache}
    end
  end

  defp cached_existing_normalization(value, cache) do
    case Map.fetch(cache, value) do
      {:ok, normalization} ->
        {normalization, cache}

      :error ->
        normalization = Domain.normalize(value)
        {normalization, cache_entry(cache, value, normalization)}
    end
  end

  defp next_line(binary) do
    case :binary.match(binary, ["\r\n", "\n", "\r"]) do
      {position, delimiter_size} ->
        rest_offset = position + delimiter_size

        {
          binary_part(binary, 0, position),
          binary_part(binary, rest_offset, byte_size(binary) - rest_offset)
        }

      :nomatch ->
        {binary, :done}
    end
  end

  defp append_domains(existing, []), do: existing

  defp append_domains(existing, domains) do
    separator = if existing == "" or :binary.last(existing) == ?\n, do: "", else: "\n"
    existing <> separator <> Enum.map_join(domains, "", &(&1 <> "\n"))
  end

  defp separator_bytes(""), do: 0
  defp separator_bytes(existing), do: if(:binary.last(existing) == ?\n, do: 0, else: 1)
end
