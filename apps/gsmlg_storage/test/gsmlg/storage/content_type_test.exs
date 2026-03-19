defmodule GSMLG.Storage.ContentTypeTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.ContentType

  describe "detect/1" do
    test "detects JPEG from magic bytes" do
      data = <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10>> <> "rest of file"
      assert {:ok, "image/jpeg"} = ContentType.detect(data)
    end

    test "detects PNG from magic bytes" do
      data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> "rest of file"
      assert {:ok, "image/png"} = ContentType.detect(data)
    end

    test "detects GIF87a" do
      assert {:ok, "image/gif"} = ContentType.detect("GIF87a" <> "rest")
    end

    test "detects GIF89a" do
      assert {:ok, "image/gif"} = ContentType.detect("GIF89a" <> "rest")
    end

    test "detects WebP" do
      data = "RIFF" <> <<100::32>> <> "WEBP" <> "rest"
      assert {:ok, "image/webp"} = ContentType.detect(data)
    end

    test "detects PDF from magic bytes" do
      data = <<0x25, 0x50, 0x44, 0x46>> <> "-1.4 rest"
      assert {:ok, "application/pdf"} = ContentType.detect(data)
    end

    test "detects ZIP from magic bytes" do
      data = <<0x50, 0x4B, 0x03, 0x04>> <> "rest"
      assert {:ok, "application/zip"} = ContentType.detect(data)
    end

    test "detects gzip from magic bytes" do
      data = <<0x1F, 0x8B>> <> "rest"
      assert {:ok, "application/gzip"} = ContentType.detect(data)
    end

    test "detects SVG with XML declaration" do
      data = ~s(<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>)
      assert {:ok, "image/svg+xml"} = ContentType.detect(data)
    end

    test "detects SVG without XML declaration" do
      data = ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)
      assert {:ok, "image/svg+xml"} = ContentType.detect(data)
    end

    test "detects HTML" do
      assert {:ok, "text/html"} = ContentType.detect("<!DOCTYPE html><html></html>")
    end

    test "returns octet-stream for unknown types" do
      assert {:ok, "application/octet-stream"} = ContentType.detect("unknown binary data here")
    end
  end

  describe "image?/1" do
    test "returns true for image types" do
      assert ContentType.image?("image/jpeg")
      assert ContentType.image?("image/png")
      assert ContentType.image?("image/webp")
      assert ContentType.image?("image/gif")
    end

    test "returns false for non-image types" do
      refute ContentType.image?("application/pdf")
      refute ContentType.image?("text/plain")
      refute ContentType.image?("application/octet-stream")
    end
  end
end
