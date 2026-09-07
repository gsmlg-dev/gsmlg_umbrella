defmodule GSMLG.AdminWeb.BrowserAPI.ByteRangeTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.BrowserAPI.ByteRange

  test "parses one bounded byte range and rejects malformed or multiple ranges" do
    assert :full = ByteRange.parse([], 10)
    assert {:ok, {2, 4}} = ByteRange.parse(["bytes=2-4"], 10)
    assert {:ok, {2, 9}} = ByteRange.parse(["bytes=2-"], 10)
    assert {:ok, {7, 9}} = ByteRange.parse(["bytes=-3"], 10)
    assert {:ok, {0, 9}} = ByteRange.parse(["bytes=0-999"], 10)

    for header <- ["bytes=10-11", "bytes=4-2", "bytes=1-2,4-5", "items=1-2", "bytes=-0"] do
      assert :invalid = ByteRange.parse([header], 10)
    end

    assert :invalid = ByteRange.parse(["bytes=0-1", "bytes=2-3"], 10)
    assert :invalid = ByteRange.parse(["bytes=0-0"], 0)
  end

  test "chunks ranges without exceeding the requested endpoint" do
    assert [{0, 3}, {4, 7}, {8, 9}] = ByteRange.chunks(0, 9, 4) |> Enum.to_list()
  end
end
