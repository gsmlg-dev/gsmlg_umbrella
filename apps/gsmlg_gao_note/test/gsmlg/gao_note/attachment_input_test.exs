defmodule GSMLG.GaoNote.AttachmentInputTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.{Attachment, AttachmentInput}

  describe "Attachment.normalize_path/1" do
    test "canonicalizes note-relative paths without rejecting harmless dots" do
      assert Attachment.normalize_path(" docs\\./report..txt ") ==
               {:ok, "./docs/report..txt"}

      assert Attachment.normalize_path("./images//./.preview..png") ==
               {:ok, "./images/.preview..png"}

      for path <- ["data.txt", "./data.txt", "././data.txt"] do
        assert Attachment.normalize_path(path) == {:ok, "./data.txt"}
      end
    end

    test "rejects blank, rooted, drive-prefixed, URL, and traversal paths" do
      for path <- [
            "",
            "  ",
            ".",
            "./",
            "/etc/passwd",
            "\\\\server\\share",
            "C:\\temp\\file.txt",
            "C:file.txt",
            "https://example.test/file.txt",
            "mailto:file@example.test",
            "./C:/temp/file.txt",
            "././C:/temp/file.txt",
            "./https://host/file.txt",
            "././https://host/file.txt",
            "../secret.txt",
            "safe/../secret.txt"
          ] do
        assert {:error, _message} = Attachment.normalize_path(path)
      end
    end
  end

  describe "cast/1 metadata" do
    test "accepts mixed known key styles, trims identity fields, and defaults description" do
      assert {:ok,
              %AttachmentInput{
                id: "attachment-id",
                path: "./docs/report..txt",
                mime: "text/plain",
                description: "",
                bytes: nil,
                upload: nil
              }} =
               AttachmentInput.cast(%{
                 "id" => " attachment-id ",
                 path: " docs\\./report..txt ",
                 "mime" => " text/plain "
               })
    end

    test "rejects unsafe prefixes hidden behind leading dot segments" do
      for path <- [
            "./https://host/file",
            "././https://host/file",
            "./C:/temp/file",
            "././C:/temp/file"
          ] do
        assert {:error, changeset} =
                 AttachmentInput.cast(Map.put(valid_attrs(), "path", path))

        assert Keyword.has_key?(changeset.errors, :path)
      end
    end

    test "requires id, path, and mime" do
      for field <- ["id", "path", "mime"] do
        attrs = Map.delete(valid_attrs(), field)

        assert {:error, changeset} = AttachmentInput.cast(attrs)
        assert Keyword.has_key?(changeset.errors, String.to_existing_atom(field))
      end
    end

    test "ignores unknown keys without creating atoms" do
      unknown_key =
        "attachment_input_unknown_#{System.unique_integer([:positive, :monotonic])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

      assert {:ok, %AttachmentInput{}} =
               valid_attrs()
               |> Map.put(unknown_key, "ignored")
               |> AttachmentInput.cast()

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
    end

    test "rejects invalid UTF-8 in every persisted text field" do
      for {input_field, changeset_field} <- text_fields() do
        assert_invalid_text_error(
          AttachmentInput.cast(Map.put(valid_attrs(), input_field, <<255>>)),
          changeset_field,
          "must be valid UTF-8"
        )
      end
    end

    test "rejects NUL bytes in every persisted text field" do
      for {input_field, changeset_field} <- text_fields() do
        assert_invalid_text_error(
          AttachmentInput.cast(
            Map.put(valid_attrs(), input_field, <<"before", 0, "after">>)
          ),
          changeset_field,
          "must not contain NUL bytes"
        )
      end
    end
  end

  describe "cast/1 content" do
    test "preserves explicitly empty text as empty bytes" do
      assert {:ok, %AttachmentInput{bytes: <<>>}} =
               AttachmentInput.cast(Map.put(valid_attrs(), "content", ""))
    end

    test "decodes strict standard padded Base64 including explicitly empty content" do
      assert {:ok, %AttachmentInput{bytes: <<0, 1, 2, 255>>}} =
               AttachmentInput.cast(
                 Map.put(valid_attrs(), "content_base64", "AAEC/w==")
               )

      assert {:ok, %AttachmentInput{bytes: <<>>}} =
               AttachmentInput.cast(Map.put(valid_attrs(), "content_base64", ""))
    end

    test "rejects invalid and unpadded Base64" do
      for content_base64 <- ["Zg", "_w==", "not base64"] do
        assert {:error, changeset} =
                 AttachmentInput.cast(
                   Map.put(valid_attrs(), "content_base64", content_base64)
                 )

        assert {"must be standard padded Base64", _metadata} =
                 Keyword.fetch!(changeset.errors, :content_base64)
      end
    end

    test "accepts dual content forms only when their bytes match" do
      assert {:ok, %AttachmentInput{bytes: "hello"}} =
               AttachmentInput.cast(
                 valid_attrs()
                 |> Map.put("content", "hello")
                 |> Map.put("content_base64", Base.encode64("hello"))
               )

      assert {:error, changeset} =
               AttachmentInput.cast(
                 valid_attrs()
                 |> Map.put("content", "hello")
                 |> Map.put("content_base64", Base.encode64("different"))
               )

      assert {"must decode to the same bytes as content", _metadata} =
               Keyword.fetch!(changeset.errors, :content_base64)
    end
  end

  describe "cast/1 internal upload" do
    test "preserves Plug.Upload without reading or publicly serializing it" do
      upload = %Plug.Upload{
        path: "/not/read/by-attachment-input",
        filename: "data.txt",
        content_type: "text/plain"
      }

      assert {:ok, %AttachmentInput{upload: ^upload, bytes: nil} = input} =
               AttachmentInput.cast(Map.put(valid_attrs(), :upload, upload))

      assert Jason.decode!(Jason.encode!(input)) == %{
               "description" => "",
               "id" => "attachment-id",
               "mime" => "text/plain",
               "path" => "./data.txt"
             }
    end

    test "preserves an internal filename and binary tuple" do
      upload = {"data.bin", <<0, 255>>}

      assert {:ok, %AttachmentInput{upload: ^upload, bytes: nil}} =
               AttachmentInput.cast(Map.put(valid_attrs(), "upload", upload))
    end

    test "rejects unsupported internal upload values" do
      assert {:error, changeset} =
               AttachmentInput.cast(Map.put(valid_attrs(), "upload", "/tmp/data.txt"))

      assert Keyword.has_key?(changeset.errors, :upload)
    end
  end

  defp valid_attrs do
    %{
      "id" => "attachment-id",
      "path" => "./data.txt",
      "mime" => "text/plain"
    }
  end

  defp text_fields do
    [
      {"id", :id},
      {"path", :path},
      {"mime", :mime},
      {"description", :description}
    ]
  end

  defp assert_invalid_text_error(result, field, message) do
    assert {:error, changeset} = result
    assert {^message, _metadata} = Keyword.fetch!(changeset.errors, field)
  end
end
