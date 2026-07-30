defmodule GSMLG.ProxyRules.SourcePageTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{SourcePage, SourceSnapshot}

  @observed_at ~U[2026-07-31 00:00:00Z]
  @fetched_at ~U[2026-07-30 23:59:00Z]

  test "pages an immutable source across version-bound cursors" do
    snapshot = snapshot("one\ntwo\nthree\n", fetched_at: @fetched_at)

    assert {:ok,
            %{
              source: :remote_gfwlist,
              version: version,
              availability: :ready,
              observed_at: @observed_at,
              last_success_at: @fetched_at,
              total_lines: 3,
              start_line: 1,
              lines: ["one", "two"],
              next_cursor: cursor,
              has_more: true
            }} =
             SourcePage.page(:remote_gfwlist, snapshot, nil,
               line_limit: 2,
               byte_limit: 1_024
             )

    assert is_binary(cursor)

    assert {:ok,
            %{
              version: ^version,
              start_line: 3,
              lines: ["three"],
              next_cursor: nil,
              has_more: false
            }} =
             SourcePage.page(:remote_gfwlist, snapshot, cursor,
               line_limit: 2,
               byte_limit: 1_024
             )
  end

  test "handles empty content and a final line without a newline" do
    assert {:ok, %{total_lines: 0, start_line: 1, lines: [], next_cursor: nil, has_more: false}} =
             SourcePage.page(:local_proxy, snapshot(""), nil, [])

    assert {:ok, %{total_lines: 2, lines: ["one", "two"], has_more: false}} =
             SourcePage.page(:local_proxy, snapshot("one\ntwo"), nil, [])
  end

  test "preserves carriage returns as source text while using LF as the line boundary" do
    assert {:ok, %{lines: ["one\r", "two\rthree"]}} =
             SourcePage.page(:remote_gfwlist, snapshot("one\r\ntwo\rthree"), nil, [])
  end

  test "clamps line and byte limits to their hard maxima" do
    content = Enum.map_join(1..501, "\n", &Integer.to_string/1)

    assert {:ok, %{lines: lines, has_more: true, next_cursor: cursor}} =
             SourcePage.page(:local_proxy, snapshot(content), nil,
               line_limit: 10_000,
               byte_limit: 10_000_000
             )

    assert length(lines) == 500
    assert is_binary(cursor)

    assert {:ok, %{lines: default_lines, has_more: true}} =
             SourcePage.page(:local_proxy, snapshot(content), nil, [])

    assert length(default_lines) == 200

    assert {:error, :page_too_large} =
             SourcePage.page(
               :local_proxy,
               snapshot(String.duplicate("x", 256 * 1024 + 1)),
               nil,
               byte_limit: 10_000_000
             )
  end

  test "rejects malformed, tampered, and version-mismatched cursors" do
    snapshot = snapshot("one\ntwo\nthree\n")

    assert {:ok, %{next_cursor: cursor}} =
             SourcePage.page(:remote_gfwlist, snapshot, nil, line_limit: 1)

    assert {:error, :invalid_cursor} =
             SourcePage.page(:remote_gfwlist, snapshot, "bad", [])

    decoded = Base.url_decode64!(cursor, padding: false)
    [version, _offset, _line] = String.split(decoded, ":")

    tampered =
      Base.url_encode64("#{version}:2:2", padding: false)

    assert {:error, :invalid_cursor} =
             SourcePage.page(:remote_gfwlist, snapshot, tampered, [])

    changed = %{snapshot | content_sha256: String.duplicate("b", 64)}

    assert {:error, :source_changed} =
             SourcePage.page(:remote_gfwlist, changed, cursor, [])
  end

  test "never returns part of a line when one line exceeds the byte limit" do
    oversized = snapshot(String.duplicate("x", 65))

    assert {:error, :page_too_large} =
             SourcePage.page(:remote_gfwlist, oversized, nil,
               line_limit: 2,
               byte_limit: 64
             )
  end

  test "rejects a line whose JSON escaping expands the encoded page beyond the byte limit" do
    line = String.duplicate("\"\\\u0001", 100)
    byte_limit = 700

    assert byte_size(line) < byte_limit
    assert byte_size(JSON.encode!(%{lines: [line]})) > byte_limit

    assert {:error, :page_too_large} =
             SourcePage.page(:remote_gfwlist, snapshot(line), nil,
               line_limit: 2,
               byte_limit: byte_limit
             )
  end

  test "stops before a line that would exceed the page byte limit" do
    one = String.duplicate("a", 100)
    two = String.duplicate("b", 100)
    three = String.duplicate("c", 100)
    snapshot = snapshot(Enum.join([one, two, three], "\n"))

    assert {:ok,
            %{lines: [^one], start_line: 1, has_more: true, next_cursor: cursor} = first_page} =
             SourcePage.page(:local_proxy, snapshot, nil, line_limit: 10, byte_limit: 500)

    assert byte_size(JSON.encode!(first_page)) <= 500

    assert {:ok, %{lines: [^two, ^three], start_line: 2, has_more: false} = final_page} =
             SourcePage.page(:local_proxy, snapshot, cursor, line_limit: 10, byte_limit: 500)

    assert byte_size(JSON.encode!(final_page)) <= 500
  end

  test "counts empty, newline-terminated, and unterminated source content" do
    assert SourceSnapshot.count_lines("") == 0
    assert SourceSnapshot.count_lines("one\n") == 1
    assert SourceSnapshot.count_lines("one\ntwo") == 2
    assert SourceSnapshot.count_lines("one\ntwo\n") == 2
  end

  defp snapshot(content, metadata \\ []) do
    %SourceSnapshot{
      kind: :remote,
      content: content,
      content_sha256: sha256(content),
      observed_at: @observed_at,
      line_count: SourceSnapshot.count_lines(content),
      metadata: Map.new(metadata),
      availability: :ready
    }
  end

  defp sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
