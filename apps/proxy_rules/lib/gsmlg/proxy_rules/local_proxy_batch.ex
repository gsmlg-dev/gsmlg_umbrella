defmodule GSMLG.ProxyRules.LocalProxyBatch do
  @moduledoc """
  Validates and prepares bare domains for appending to the local proxy source.

  Submitted domains may include one optional Squid-style leading dot or
  wildcard prefix. The `.` or `*.` prefix is removed before canonicalization
  and storage.

  Invalid batches retain up to 100 concrete line errors. When more errors are
  found, the result appends one `:too_many_errors` marker at the first omitted
  error line. Textarea input larger than `:max_bytes` is rejected before line
  validation, even when duplicate removal could make the final body smaller.
  A batch may submit at most 10,000 distinct canonical domains after
  within-batch deduplication. Matches already present in the existing source
  still count toward this safety limit; repeated input lines do not.
  """

  alias GSMLG.ProxyRules.Domain

  @max_line_errors 100
  @max_cache_entries 1_024
  @max_distinct_domains 10_000

  @type rejection_reason ::
          :leading_dot_not_allowed
          | :trailing_dot_not_allowed
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
          | :too_many_domains
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

  @doc "Returns the maximum number of distinct canonical domains one batch may submit."
  @spec max_distinct_domains() :: pos_integer()
  def max_distinct_domains, do: @max_distinct_domains

  defp initial_state(existing, max_bytes) do
    existing_bytes = byte_size(existing)
    oversized? = existing_bytes > max_bytes

    %{
      mode: if(oversized?, do: :body_too_large, else: :valid),
      seen: if(oversized?, do: nil, else: MapSet.new()),
      cache: %{},
      added_domains: [],
      distinct_count: 0,
      duplicate_count: 0,
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
    cache? = state.mode == :valid
    {validation, cache} = validate_submitted_line(raw_line, state.cache, cache?)
    state = %{state | cache: cache}

    case validation do
      :blank -> state
      {:ok, domain} -> accept_domain(%{state | nonblank?: true}, domain)
      {:error, reason} -> retain_error(%{state | nonblank?: true}, line_number, reason)
    end
  end

  defp validate_submitted_line(raw_line, cache, cache?) do
    if String.valid?(raw_line) do
      value = String.trim(raw_line)

      case value do
        "" ->
          {:blank, cache}

        value ->
          cached_submitted_validation(value, cache, cache?)
      end
    else
      {{:error, :invalid_utf8}, cache}
    end
  end

  defp cached_submitted_validation(value, cache, false), do: {validate_line(value), cache}

  defp cached_submitted_validation(value, cache, true) do
    case Map.fetch(cache, value) do
      {:ok, validation} -> {validation, cache}
      :error -> cache_validation(value, cache)
    end
  end

  defp cache_validation(value, cache) do
    validation = validate_line(value)
    {validation, cache_entry(cache, value, validation)}
  end

  defp cache_entry(cache, key, value) when map_size(cache) < @max_cache_entries,
    do: Map.put(cache, key, value)

  defp cache_entry(cache, key, value) do
    {evicted_key, _evicted_value, _iterator} = cache |> :maps.iterator() |> :maps.next()

    cache
    |> Map.delete(evicted_key)
    |> Map.put(key, value)
  end

  defp accept_domain(%{mode: :valid} = state, domain), do: add_domain(state, domain)
  defp accept_domain(state, _domain), do: state

  defp add_domain(state, domain) do
    if MapSet.member?(state.seen, domain) do
      %{state | duplicate_count: state.duplicate_count + 1}
    else
      add_distinct_domain(state, domain)
    end
  end

  defp add_distinct_domain(%{distinct_count: @max_distinct_domains} = state, _domain),
    do: discard_valid_result(state, :too_many_domains)

  defp add_distinct_domain(state, domain) do
    %{
      state
      | seen: MapSet.put(state.seen, domain),
        added_domains: [domain | state.added_domains],
        distinct_count: state.distinct_count + 1
    }
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
        cache: %{},
        added_domains: [],
        distinct_count: 0,
        duplicate_count: 0
    }
  end

  defp build_result(%{errors: errors} = state, _existing, _max_bytes) when errors != [] do
    errors = format_errors(errors, state.first_omitted_error_line)
    {:error, {:invalid_batch, errors}}
  end

  defp build_result(%{nonblank?: false}, _existing, _max_bytes), do: {:error, :empty_batch}

  defp build_result(%{mode: :body_too_large}, _existing, _max_bytes),
    do: {:error, :body_too_large}

  defp build_result(%{mode: :too_many_domains}, _existing, _max_bytes),
    do: {:error, :too_many_domains}

  defp build_result(state, existing, max_bytes) do
    {pending, existing_duplicate_count} =
      scan_existing_matches(existing, state.seen, 0, %{})

    added_domains =
      state.added_domains
      |> Enum.reverse()
      |> Enum.filter(&MapSet.member?(pending, &1))

    content = append_domains(existing, added_domains)

    if byte_size(content) <= max_bytes do
      {:ok,
       %{
         content: content,
         added_domains: added_domains,
         added_count: state.distinct_count - existing_duplicate_count,
         duplicate_count: state.duplicate_count + existing_duplicate_count
       }}
    else
      {:error, :body_too_large}
    end
  end

  defp format_errors(errors, nil), do: Enum.reverse(errors)

  defp format_errors(errors, first_omitted_error_line) do
    Enum.reverse(errors) ++ [%{line: first_omitted_error_line, reason: :too_many_errors}]
  end

  defp validate_line(".." <> _rest), do: {:error, :leading_dot_not_allowed}
  defp validate_line("*.." <> _rest), do: {:error, :wildcard_not_allowed}
  defp validate_line("*." <> value), do: validate_bare_line(value)
  defp validate_line("." <> value), do: validate_bare_line(value)
  defp validate_line(value), do: validate_bare_line(value)

  defp validate_bare_line(value) do
    cond do
      String.ends_with?(value, ".") ->
        {:error, :trailing_dot_not_allowed}

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
        normalize_submitted_domain(value)
    end
  end

  defp normalize_submitted_domain(value) do
    case fast_ascii_domain(value) do
      {:ok, domain} ->
        {:ok, domain}

      :fallback ->
        case Domain.normalize(value) do
          {:ok, domain} -> {:ok, domain.name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ip_literal?(value) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(value)))
  end

  defp scan_existing_matches(existing, pending, duplicate_count, cache) do
    if MapSet.size(pending) == 0 do
      {pending, duplicate_count}
    else
      {raw_line, rest} = next_line(existing)

      {pending, duplicate_count, cache} =
        match_existing_line(raw_line, pending, duplicate_count, cache)

      case rest do
        :done -> {pending, duplicate_count}
        rest -> scan_existing_matches(rest, pending, duplicate_count, cache)
      end
    end
  end

  defp match_existing_line(raw_line, pending, duplicate_count, cache) do
    case fast_ascii_domain(raw_line) do
      {:ok, domain} ->
        remove_existing_match(domain, pending, duplicate_count, cache)

      :fallback ->
        match_noncanonical_existing_line(raw_line, pending, duplicate_count, cache)
    end
  end

  defp match_noncanonical_existing_line(raw_line, pending, duplicate_count, cache) do
    if String.valid?(raw_line) do
      value = String.trim(raw_line)

      cond do
        value == "" or String.starts_with?(value, ["#", "!"]) ->
          {pending, duplicate_count, cache}

        true ->
          match_trimmed_existing_value(value, pending, duplicate_count, cache)
      end
    else
      {pending, duplicate_count, cache}
    end
  end

  defp match_trimmed_existing_value(value, pending, duplicate_count, cache) do
    case fast_ascii_domain(value) do
      {:ok, domain} ->
        remove_existing_match(domain, pending, duplicate_count, cache)

      :fallback ->
        {normalization, cache} = cached_existing_normalization(value, cache)

        case normalization do
          {:ok, domain} ->
            remove_existing_match(domain.name, pending, duplicate_count, cache)

          {:error, _reason} ->
            {pending, duplicate_count, cache}
        end
    end
  end

  defp remove_existing_match(domain, pending, duplicate_count, cache) do
    if MapSet.member?(pending, domain) do
      {MapSet.delete(pending, domain), duplicate_count + 1, cache}
    else
      {pending, duplicate_count, cache}
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

  defp fast_ascii_domain(value) do
    bare = value |> remove_fast_leading_dot() |> remove_fast_trailing_dot()

    if byte_size(bare) <= 253 and ascii_bare_domain?(bare, 0, nil) do
      {:ok, String.downcase(bare, :ascii)}
    else
      :fallback
    end
  end

  defp ascii_bare_domain?(<<>>, label_size, last_byte),
    do: label_size > 0 and last_byte != ?-

  defp ascii_bare_domain?(<<"--", _rest::binary>>, 2, _last_byte), do: false

  defp ascii_bare_domain?(<<".", rest::binary>>, label_size, last_byte)
       when label_size > 0 and last_byte != ?-,
       do: ascii_bare_domain?(rest, 0, nil)

  defp ascii_bare_domain?(<<byte, rest::binary>>, label_size, _last_byte)
       when label_size < 63 and
              (byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or
                 (byte == ?- and label_size > 0)),
       do: ascii_bare_domain?(rest, label_size + 1, byte)

  defp ascii_bare_domain?(_value, _label_size, _last_byte), do: false

  defp remove_fast_leading_dot(<<".", rest::binary>>), do: rest
  defp remove_fast_leading_dot(value), do: value

  defp remove_fast_trailing_dot(""), do: ""

  defp remove_fast_trailing_dot(value) do
    if :binary.last(value) == ?. do
      binary_part(value, 0, byte_size(value) - 1)
    else
      value
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
end
