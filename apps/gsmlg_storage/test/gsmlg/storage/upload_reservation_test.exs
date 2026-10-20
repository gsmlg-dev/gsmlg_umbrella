defmodule GSMLG.Storage.UploadReservationTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, StorageFile, TestCatalogClient}

  defmodule ObjectStore do
    def put_file(bucket, key, path, content_type) do
      send(self(), {:put_file, bucket, key, File.read!(path), content_type})
      :ok
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    TestCatalogClient.setup!()

    directory =
      Path.join(System.tmp_dir!(), "storage-reservation-#{System.unique_integer([:positive])}")

    old_directory = Application.get_env(:gsmlg_storage, :upload_reservation_dir)
    Application.put_env(:gsmlg_storage, :upload_reservation_dir, directory)

    on_exit(fn ->
      File.rm_rf(directory)

      if old_directory,
        do: Application.put_env(:gsmlg_storage, :upload_reservation_dir, old_directory),
        else: Application.delete_env(:gsmlg_storage, :upload_reservation_dir)
    end)

    :ok
  end

  test "durably reserves, bounded-streams, rehashes Markdown, and finalizes storage" do
    content = "# Browser report\n"

    attrs = %{
      filename: "report.md",
      content_type: "text/markdown",
      size: byte_size(content),
      checksum: sha256(content),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    assert {:ok, %StorageFile{status: "processing"} = reservation} =
             Storage.prepare_upload("browser", "browser_artifact", attrs,
               max_bytes: byte_size(content)
             )

    assert {:ok, %StorageFile{status: "processing", id: id}} = Catalog.fetch(reservation.id)
    assert id == reservation.id
    assert Repo.get(StorageFile, reservation.id) == nil
    assert :ok = Storage.write_upload(reservation.id, "# Browser ")
    assert :ok = Storage.write_upload(reservation.id, "report\n")

    assert {:ok, %StorageFile{status: "active"}} =
             Storage.finalize_upload(reservation.id, s3_client: ObjectStore)

    assert_received {:put_file, _bucket, _key, ^content, "text/markdown"}
    assert %StorageFile{status: "active"} = Storage.get(reservation.id)
    assert Repo.get(StorageFile, reservation.id) == nil
  end

  test "rejects overflow and integrity mismatch while retaining a recoverable deleted reservation" do
    content = "{}"

    attrs = %{
      filename: "report.json",
      content_type: "application/json",
      size: byte_size(content),
      checksum: sha256(content),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    {:ok, reservation} =
      Storage.prepare_upload("browser", "browser_artifact", attrs, max_bytes: 10)

    assert {:error, :upload_too_large} = Storage.write_upload(reservation.id, "toolong")
    assert :ok = Storage.write_upload(reservation.id, "[]")

    assert {:error, :upload_integrity_failed} =
             Storage.finalize_upload(reservation.id, s3_client: ObjectStore)

    assert {:ok, %StorageFile{status: "deleted"}} = Storage.reject_upload(reservation.id)
    assert {:ok, %StorageFile{status: "deleted"}} = Catalog.fetch(reservation.id)
    assert Repo.get(StorageFile, reservation.id) == nil
    refute_received {:put_file, _, _, _, _}
  end

  test "finalizes UTF-8 CSV whose sampled header ends within a character" do
    content = String.duplicate("a", 4095) <> "中,value\n"
    refute String.valid?(binary_part(content, 0, 4096))

    reservation = reserve_csv(content)
    assert :ok = Storage.write_upload(reservation.id, content)

    assert {:ok, %StorageFile{status: "active", content_type: "text/csv"}} =
             Storage.finalize_upload(reservation.id, s3_client: ObjectStore)

    assert_received {:put_file, _, _, ^content, "text/csv"}
  end

  test "rejects invalid UTF-8 beyond the sampled header despite matching size and checksum" do
    for suffix <- [<<0xFF>>, <<0xE4, 0xB8>>, <<0>>, <<0x01>>] do
      content = String.duplicate("a", 4096) <> suffix
      reservation = reserve_csv(content)
      assert :ok = Storage.write_upload(reservation.id, content)

      assert {:error, :upload_integrity_failed} =
               Storage.finalize_upload(reservation.id, s3_client: ObjectStore)

      refute_received {:put_file, _, _, _, _}
    end
  end

  defp reserve_csv(content) do
    attrs = %{
      filename: "report.csv",
      content_type: "text/csv",
      size: byte_size(content),
      checksum: sha256(content),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    {:ok, reservation} =
      Storage.prepare_upload("sync", "gao_note_attachment", attrs, max_bytes: byte_size(content))

    reservation
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
