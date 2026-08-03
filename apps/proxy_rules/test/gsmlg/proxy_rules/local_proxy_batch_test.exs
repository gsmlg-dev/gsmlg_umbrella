defmodule GSMLG.ProxyRules.LocalProxyBatchTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.LocalProxyBatch

  describe "prepare/3" do
    test "normalizes and appends only unique submitted domains" do
      existing = "# operator note\nexisting.com\n"
      input = "Baidu.com\n例子.测试\nbaidu.com\nexisting.com\n"

      assert {:ok,
              %{
                content:
                  "# operator note\nexisting.com\n" <>
                    "baidu.com\nxn--fsqu00a.xn--0zwm56d\n",
                added_domains: ["baidu.com", "xn--fsqu00a.xn--0zwm56d"],
                added_count: 2,
                duplicate_count: 2
              }} = LocalProxyBatch.prepare(existing, input, max_bytes: 8 * 1024 * 1024)
    end

    test "returns every invalid line without preparing partial content" do
      assert {:error,
              {:invalid_batch,
               [
                 %{line: 2, reason: :url_not_allowed},
                 %{line: 3, reason: :ip_literal}
               ]}} =
               LocalProxyBatch.prepare(
                 "",
                 "ok.example\nhttps://bad.example\n127.0.0.1\n",
                 max_bytes: 8 * 1024 * 1024
               )
    end

    test "keeps one-based line numbers across CR, LF, and CRLF" do
      input = "ok.example\rhttps://bad.example\r\n \n127.0.0.1"

      assert {:error,
              {:invalid_batch,
               [
                 %{line: 2, reason: :url_not_allowed},
                 %{line: 4, reason: :ip_literal}
               ]}} = LocalProxyBatch.prepare("", input, max_bytes: 1_024)
    end

    test "rejects an empty or whitespace-only batch" do
      assert {:error, :empty_batch} =
               LocalProxyBatch.prepare("existing.example\n", "", max_bytes: 1_024)

      assert {:error, :empty_batch} =
               LocalProxyBatch.prepare("existing.example\n", " \n\t\r\n", max_bytes: 1_024)
    end

    test "rejects non-domain input forms before domain normalization" do
      input = """
      ok.example
      .leading.example
      # comment
      ! legacy comment
      *.wildcard.example
      path.example/rule
      192.0.2.0/24
      2001:db8::1
      xn--a.example
      """

      assert {:error,
              {:invalid_batch,
               [
                 %{line: 2, reason: :leading_dot_not_allowed},
                 %{line: 3, reason: :comment_not_allowed},
                 %{line: 4, reason: :comment_not_allowed},
                 %{line: 5, reason: :wildcard_not_allowed},
                 %{line: 6, reason: :path_not_allowed},
                 %{line: 7, reason: :path_not_allowed},
                 %{line: 8, reason: :ip_literal},
                 %{line: 9, reason: :invalid_idna}
               ]}} = LocalProxyBatch.prepare("", input, max_bytes: 1_024)
    end

    test "accepts CRLF input and treats legacy leading-dot entries as existing domains" do
      existing = "# keep this comment\r\n.Existing.COM\r\nlegacy/path"

      assert {:ok,
              %{
                content: ^existing,
                added_domains: [],
                added_count: 0,
                duplicate_count: 2
              }} =
               LocalProxyBatch.prepare(
                 existing,
                 " Existing.com \r\n\r\nEXISTING.COM\r\n",
                 max_bytes: 1_024
               )
    end

    test "preserves an existing body byte-for-byte before appended domains" do
      existing = "# CRLF comment\r\n.Legacy.EXAMPLE"

      assert {:ok,
              %{
                content: "# CRLF comment\r\n.Legacy.EXAMPLE\nnew.example\n",
                added_domains: ["new.example"],
                added_count: 1,
                duplicate_count: 1
              }} =
               LocalProxyBatch.prepare(
                 existing,
                 "legacy.example\r\nnew.example\r\n",
                 max_bytes: 1_024
               )
    end

    test "rejects a valid batch when the final body exceeds the byte limit" do
      existing = "# operator note\n"
      final_content = existing <> "new.example\n"

      assert {:ok, %{content: ^final_content}} =
               LocalProxyBatch.prepare(existing, "new.example",
                 max_bytes: byte_size(final_content)
               )

      assert {:error, :body_too_large} =
               LocalProxyBatch.prepare(existing, "new.example",
                 max_bytes: byte_size(final_content) - 1
               )
    end

    test "requires max_bytes to be a non-negative integer" do
      for invalid <- [-1, 1.5, "5", nil] do
        assert_raise ArgumentError, ~r/max_bytes/, fn ->
          LocalProxyBatch.prepare("", "new.example", max_bytes: invalid)
        end
      end

      assert {:error, :body_too_large} =
               LocalProxyBatch.prepare("", "new.example", max_bytes: 0)
    end

    test "bounds textarea bytes before validation or duplicate shrinking" do
      duplicate_input = "a.co\na.co\n"

      assert byte_size(duplicate_input) > 5

      assert {:error, :body_too_large} =
               LocalProxyBatch.prepare("", duplicate_input, max_bytes: 5)

      assert {:error, :body_too_large} =
               LocalProxyBatch.prepare("", <<255, 255>>, max_bytes: 1)
    end

    test "returns a bounded line error for invalid UTF-8 input" do
      input = <<"ok.example\n", 255, "\nnext.example\n">>

      assert {:error, {:invalid_batch, [%{line: 2, reason: :invalid_utf8}]}} =
               LocalProxyBatch.prepare("", input, max_bytes: 1_024)
    end

    test "ignores invalid UTF-8 legacy lines while preserving the existing body" do
      existing = <<"# keep\n", 255, "\nexisting.com\n">>

      assert {:ok,
              %{
                content: <<^existing::binary, "new.example\n">>,
                added_domains: ["new.example"],
                added_count: 1,
                duplicate_count: 1
              }} =
               LocalProxyBatch.prepare(existing, "existing.com\nnew.example", max_bytes: 1_024)
    end

    test "retains 100 concrete errors then marks the first omitted error" do
      concrete_errors =
        for line <- 1..100, do: %{line: line, reason: :url_not_allowed}

      one_hundred =
        1..100
        |> Enum.map_join("\n", &"https://bad#{&1}.example")

      assert {:error, {:invalid_batch, ^concrete_errors}} =
               LocalProxyBatch.prepare("", one_hundred, max_bytes: 8 * 1024 * 1024)

      one_hundred_and_one = one_hundred <> "\nhttps://bad101.example"
      capped_errors = concrete_errors ++ [%{line: 101, reason: :too_many_errors}]

      assert {:error, {:invalid_batch, ^capped_errors}} =
               LocalProxyBatch.prepare("", one_hundred_and_one, max_bytes: 8 * 1024 * 1024)
    end

    @tag timeout: 60_000
    test "drops valid-result state after the first error" do
      valid_tail = Enum.map_join(1..50_000, "\n", &"unique#{&1}.example")
      input = "https://bad.example\n" <> valid_tail

      assert {:error, {:invalid_batch, [%{line: 1, reason: :url_not_allowed}]}} =
               prepare_under_heap_limit("", input, max_bytes: 8 * 1024 * 1024)
    end

    @tag timeout: 60_000
    test "keeps candidate state bounded when the final body exceeds the limit" do
      max_bytes = 2 * 1024 * 1024
      existing = "#" <> String.duplicate("x", max_bytes - 1)
      input = Enum.map_join(1..10_000, "\n", &"unique#{&1}.example")

      assert byte_size(input) <= max_bytes

      assert {:error, :body_too_large} =
               prepare_under_heap_limit(
                 existing,
                 input,
                 [max_bytes: max_bytes],
                 2_000_000
               )
    end

    test "invalid lines win when the final body would overflow for an in-limit input" do
      existing = String.duplicate("a", 63) <> ".example\n"
      input = "new.example\nhttps://bad.example"
      max_bytes = byte_size(existing)

      assert byte_size(input) <= max_bytes

      assert {:error, {:invalid_batch, [%{line: 2, reason: :url_not_allowed}]}} =
               LocalProxyBatch.prepare(existing, input, max_bytes: max_bytes)
    end

    @tag timeout: 60_000
    test "accepts exactly the maximum number of distinct submitted domains" do
      max_distinct_domains = 10_000
      domains = Enum.map(1..max_distinct_domains, &"unique#{&1}.example")
      input = Enum.join(domains, "\n")

      assert LocalProxyBatch.max_distinct_domains() == max_distinct_domains

      assert {:ok,
              %{
                added_domains: ^domains,
                added_count: ^max_distinct_domains,
                duplicate_count: 0
              }} =
               prepare_under_heap_limit(
                 "",
                 input,
                 [max_bytes: 8 * 1024 * 1024],
                 2_000_000
               )
    end

    test "rejects the 10,001st distinct submitted domain without partial content" do
      input = Enum.map_join(1..10_001, "\n", &"unique#{&1}.example")

      assert {:error, :too_many_domains} =
               LocalProxyBatch.prepare("", input, max_bytes: 8 * 1024 * 1024)
    end

    test "invalid lines win after the distinct submitted domain limit for an in-limit input" do
      input =
        Enum.map_join(1..10_001, "\n", &"unique#{&1}.example") <>
          "\nhttps://bad.example"

      assert {:error, {:invalid_batch, [%{line: 10_002, reason: :url_not_allowed}]}} =
               LocalProxyBatch.prepare("", input, max_bytes: 8 * 1024 * 1024)
    end

    test "counts an existing match within the 10,000 distinct submitted domains" do
      new_domains = Enum.map(1..9_999, &"unique#{&1}.example")
      input = Enum.join(["existing.example" | new_domains], "\n")

      assert {:ok,
              %{
                added_domains: ^new_domains,
                added_count: 9_999,
                duplicate_count: 1
              }} = LocalProxyBatch.prepare("existing.example\n", input, max_bytes: 1_000_000)
    end

    test "rejects one existing match plus 10,000 new submitted domains" do
      input =
        Enum.join(
          ["existing.example" | Enum.map(1..10_000, &"unique#{&1}.example")],
          "\n"
        )

      assert {:error, :too_many_domains} =
               LocalProxyBatch.prepare("existing.example\n", input, max_bytes: 1_000_000)
    end

    test "rejects more than 10,000 distinct submitted domains even when all already exist" do
      domains = Enum.map(1..10_001, &"existing#{&1}.example")
      existing = Enum.join(domains, "\n") <> "\n"
      input = Enum.join(domains, "\n")

      assert {:error, :too_many_domains} =
               LocalProxyBatch.prepare(existing, input, max_bytes: 1_000_000)
    end

    test "allows repeated lines for one existing domain and counts every duplicate" do
      repetitions = 10_001
      input = :binary.copy("existing.example\n", repetitions)

      assert {:ok,
              %{
                content: "existing.example\n",
                added_domains: [],
                added_count: 0,
                duplicate_count: ^repetitions
              }} =
               LocalProxyBatch.prepare("existing.example\n", input, max_bytes: 1_000_000)
    end

    test "counts an existing match once per unique submitted domain" do
      existing = "existing.example\nexisting.example\n"
      input = "existing.example\nexisting.example\nnew.example"

      assert {:ok,
              %{
                content: "existing.example\nexisting.example\nnew.example\n",
                added_domains: ["new.example"],
                added_count: 1,
                duplicate_count: 2
              }} = LocalProxyBatch.prepare(existing, input, max_bytes: 1_024)
    end

    @tag timeout: 120_000
    test "keeps an 8 MiB distinct canonical existing-source scan bounded" do
      existing =
        for number <- 1..648_968, into: "" do
          String.downcase(Integer.to_string(number, 36)) <> ".example\n"
        end

      assert byte_size(existing) == 8_388_599

      assert {:error, :body_too_large} =
               prepare_under_heap_limit(
                 existing,
                 "not-in-source.test",
                 [max_bytes: 8 * 1024 * 1024],
                 2_000_000
               )
    end

    @tag timeout: 120_000
    test "keeps the result bounded for an 8 MiB repeated-domain batch" do
      repetitions = div(8 * 1024 * 1024, byte_size("a.co\n"))
      input = :binary.copy("a.co\n", repetitions)
      expected_duplicates = repetitions - 1

      assert {:ok,
              %{
                content: "a.co\n",
                added_domains: ["a.co"],
                added_count: 1,
                duplicate_count: ^expected_duplicates
              }} = LocalProxyBatch.prepare("", input, max_bytes: 8 * 1024 * 1024)
    end
  end

  defp prepare_under_heap_limit(existing, input, options, heap_words \\ 500_000) do
    caller = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(caller, {self(), LocalProxyBatch.prepare(existing, input, options)}) end,
        [:monitor, {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}]
      )

    receive do
      {^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("batch process exited before returning: #{inspect(reason)}")
    after
      30_000 ->
        Process.exit(pid, :kill)
        flunk("batch process did not return within 30 seconds")
    end
  end
end
