defmodule GSMLG.GaoNote.ByteRangeTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.ByteRange

  describe "parse/2" do
    test "treats an absent Range header as a full response, including zero bytes" do
      assert ByteRange.parse([], 10) == :full
      assert ByteRange.parse([], 0) == :full
    end

    test "normalizes closed, open-ended, and suffix ranges inclusively" do
      assert ByteRange.parse(["bytes=2-5"], 10) == {:ok, {2, 5}}
      assert ByteRange.parse(["bytes=6-"], 10) == {:ok, {6, 9}}
      assert ByteRange.parse(["bytes=-3"], 10) == {:ok, {7, 9}}
      assert ByteRange.parse(["bytes=-20"], 10) == {:ok, {0, 9}}
      assert ByteRange.parse(["bytes=7-99"], 10) == {:ok, {7, 9}}
      assert ByteRange.parse(["BYTES=0-0"], 10) == {:ok, {0, 0}}
    end

    test "rejects malformed, multiple, and unsatisfiable ranges" do
      for headers <- [
            [""],
            ["items=0-1"],
            ["bytes="],
            ["bytes=abc-def"],
            ["bytes=1"],
            ["bytes=5-2"],
            ["bytes=10-"],
            ["bytes=-0"],
            ["bytes=0-1,4-5"],
            ["bytes=+1-2"],
            ["bytes=1 - 2"],
            ["bytes=999999999999999999999-"],
            ["bytes=0-1", "bytes=2-3"]
          ] do
        assert ByteRange.parse(headers, 10) == :invalid
      end
    end

    test "rejects every range against a zero-byte object" do
      for header <- ["bytes=0-0", "bytes=0-", "bytes=-1"] do
        assert ByteRange.parse([header], 0) == :invalid
      end
    end
  end

  describe "chunks/3" do
    test "plans bounded inclusive chunks without materializing object bytes" do
      assert ByteRange.chunks(0, 131_088, 65_536) |> Enum.to_list() == [
               {0, 65_535},
               {65_536, 131_071},
               {131_072, 131_088}
             ]
    end

    test "returns no chunks for invalid bounds" do
      assert ByteRange.chunks(2, 1, 65_536) == []
      assert ByteRange.chunks(0, 1, 0) == []
    end
  end
end
