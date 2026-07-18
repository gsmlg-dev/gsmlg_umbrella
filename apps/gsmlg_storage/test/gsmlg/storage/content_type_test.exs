defmodule GSMLG.Storage.ContentTypeTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.ContentType

  describe "detect/1" do
    test "detects AVIF primary brands before generic MP4" do
      for brand <- ["avif", "avis"] do
        data =
          <<24::32, "ftyp", brand::binary-size(4), 0::32, "mif1", "miaf">>

        assert ContentType.detect(data) == {:ok, "image/avif"}
      end
    end

    test "detects AVIF compatible brands at four-byte brand positions" do
      avif_data =
        <<28::32, "ftyp", "mif1", 0::32, "mif1", "avif", "miaf">>

      avis_data =
        <<28::32, "ftyp", "mif1", 0::32, "mif1", "miaf", "avis">>

      assert ContentType.detect(avif_data) == {:ok, "image/avif"}
      assert ContentType.detect(avis_data) == {:ok, "image/avif"}
    end

    test "keeps ordinary ISO-BMFF files as MP4" do
      data =
        <<24::32, "ftyp", "isom", 0::32, "isom", "mp42">>

      assert ContentType.detect(data) == {:ok, "video/mp4"}
    end

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

    test "returns octet-stream for binary data without a known signature" do
      assert {:ok, "application/octet-stream"} = ContentType.detect(<<0x00, 0x01, 0x02, 0xFF>>)
    end

    test "classifies safe text without filename context as plain text" do
      assert {:ok, "text/plain"} = ContentType.detect("plain text content")
    end
  end

  describe "detect/2" do
    test "classifies ASCII and UTF-8 .txt content as plain text" do
      assert {:ok, "text/plain"} = ContentType.detect("plain ASCII text", "notes.txt")
      assert {:ok, "text/plain"} = ContentType.detect("UTF-8 text: \u4f60\u597d", "notes.txt")
    end

    test "classifies extensionless and unknown-extension safe text as plain text" do
      assert {:ok, "text/plain"} = ContentType.detect("plain text", "README")
      assert {:ok, "text/plain"} = ContentType.detect("plain text", "notes.rst")
    end

    test "maps constrained text extensions" do
      assert {:ok, "text/markdown"} = ContentType.detect("# Markdown", "notes.md")
      assert {:ok, "text/markdown"} = ContentType.detect("# Markdown", "notes.markdown")
      assert {:ok, "application/json"} = ContentType.detect(~s({"ok":true}), "data.json")
      assert {:ok, "text/csv"} = ContentType.detect("name,value\nalpha,1\n", "data.csv")
      assert {:ok, "text/xml"} = ContentType.detect("<document>text</document>", "data.xml")
    end

    test "allows tab, LF, and CR in safe text" do
      assert {:ok, "text/plain"} =
               ContentType.detect("column\tvalue\nnext\rline", "notes.txt")
    end

    test "lets PNG magic bytes override a .txt filename" do
      data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> "rest"
      assert {:ok, "image/png"} = ContentType.detect(data, "image.txt")
    end

    test "retains active HTML and SVG detection for .txt filenames" do
      assert {:ok, "text/html"} =
               ContentType.detect("<!DOCTYPE html><html></html>", "page.txt")

      assert {:ok, "image/svg+xml"} =
               ContentType.detect(~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>), "image.txt")
    end

    test "rejects HTML and SVG prefixes followed by NUL" do
      for data <- ["<!DOCTYPE html><html>\0</html>", "<svg>\0</svg>"] do
        assert {:ok, "application/octet-stream"} = ContentType.detect(data, "active.txt")
      end
    end

    test "rejects HTML and SVG prefixes with invalid UTF-8" do
      for data <- [<<"<!DOCTYPE html><html>", 0xFF>>, <<"<svg>", 0xFF>>] do
        assert {:ok, "application/octet-stream"} = ContentType.detect(data, "active.txt")
      end
    end

    test "rejects HTML and SVG prefixes with disallowed controls" do
      for data <- [<<"<!DOCTYPE html><html>", 0x01>>, <<"<svg>", 0x7F>>] do
        assert {:ok, "application/octet-stream"} = ContentType.detect(data, "active.txt")
      end
    end

    test "binary magic still wins when trailing data is not safe text" do
      data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF>>
      assert {:ok, "image/png"} = ContentType.detect(data, "image.txt")
    end

    test "rejects invalid UTF-8 even with a .txt filename" do
      assert {:ok, "application/octet-stream"} =
               ContentType.detect(<<"invalid", 0xFF>>, "notes.txt")
    end

    test "rejects NUL-containing content even with a .txt filename" do
      assert {:ok, "application/octet-stream"} =
               ContentType.detect(<<"before", 0x00, "after">>, "notes.txt")
    end

    test "rejects disallowed control characters even with a .txt filename" do
      assert {:ok, "application/octet-stream"} =
               ContentType.detect(<<"before", 0x01, "after">>, "notes.txt")
    end

    test "lets ZIP magic bytes override an Office filename" do
      data = <<0x50, 0x4B, 0x03, 0x04>> <> "arbitrary ZIP content"
      assert {:ok, "application/zip"} = ContentType.detect(data, "document.docx")
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
