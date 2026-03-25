defmodule GSMLG.Web.FileControllerTest do
  use GSMLG.Web.ConnCase

  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @valid_attrs %{
    tenant: "test",
    type: "attachment",
    filename: "test.jpg",
    s3_key: "test/attachment/2026/03/test-uuid.jpg",
    content_type: "image/jpeg",
    size: 1024,
    checksum: "abc123def456",
    metadata: %{},
    variants: %{
      "thumb" => %{
        "s3_key" => "test/attachment/2026/03/test-uuid_thumb.webp",
        "size" => 512,
        "content_type" => "image/webp"
      }
    },
    status: "active",
    uploaded_by: "test"
  }

  defp insert_file(attrs \\ %{}) do
    %StorageFile{}
    |> StorageFile.changeset(Map.merge(@valid_attrs, attrs))
    |> Repo.insert!()
  end

  describe "GET /files/:id" do
    test "returns 404 for non-existent file", %{conn: conn} do
      conn = get(conn, "/files/#{Ecto.UUID.generate()}")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for invalid UUID", %{conn: conn} do
      conn = get(conn, "/files/not-a-uuid")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for deleted file", %{conn: conn} do
      file = insert_file(%{status: "deleted"})
      conn = get(conn, "/files/#{file.id}")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for processing file", %{conn: conn} do
      file = insert_file(%{status: "processing"})
      conn = get(conn, "/files/#{file.id}")
      assert response(conn, 404) =~ "Not Found"
    end
  end

  describe "GET /files/:id/v/:variant" do
    test "returns 404 for non-existent file", %{conn: conn} do
      conn = get(conn, "/files/#{Ecto.UUID.generate()}/v/thumb")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for non-existent variant", %{conn: conn} do
      file = insert_file(%{variants: %{}})

      conn = get(conn, "/files/#{file.id}/v/nonexistent")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for file with nil variants", %{conn: conn} do
      file = insert_file(%{variants: nil})

      conn = get(conn, "/files/#{file.id}/v/thumb")
      assert response(conn, 404) =~ "Not Found"
    end
  end

  describe "ETag / 304 handling" do
    test "returns 304 when If-None-Match matches checksum", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("if-none-match", ~s("#{file.checksum}"))
        |> get("/files/#{file.id}")

      assert conn.status == 304
      assert get_resp_header(conn, "etag") == [~s("#{file.checksum}")]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    @tag :requires_s3
    test "does not return 304 when If-None-Match does not match", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("if-none-match", ~s("wrong-checksum"))
        |> get("/files/#{file.id}")

      # Requires S3/AWS services running. When ETag doesn't match, controller
      # fetches from S3 — returns 200 with data or 404 on S3 error.
      assert conn.status in [200, 404]
      refute conn.status == 304
    end
  end
end
