defmodule GSMLGDNSTest do
  use ExUnit.Case
  doctest GSMLGDNS

  describe "resolve" do
    test "defaults DNS servers" do
      {:ok, results} = GSMLGDNS.resolve("gsmlg.org")

      assert is_list(results)
      assert length(results) > 0
    end

    test "can query custom DNS servers" do
      {:ok, results} = GSMLGDNS.resolve("gsmlg.org", :a, {"8.8.4.4", 53})

      assert is_list(results)
      assert length(results) > 0
    end

    test "responds with error if domain not found" do
      assert {:error, :not_found} = GSMLGDNS.resolve('uifqourefhoqeirhfqeurfhqehfqoerfiuqe.com')
    end

    test "can query DNS servers via tcp" do
      {:ok, results} = GSMLGDNS.resolve("gsmlg.org", :a, {"8.8.4.4", 53}, :tcp)

      assert is_list(results)
      assert length(results) > 0
    end
  end
end
