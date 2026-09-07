defmodule GSMLG.Storage.UploadReservationTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  defmodule ObjectStore do
    def put_file(bucket, key, path, content_type) do
      send(self(), {:put_file, bucket, key, File.read!(path), content_type})
      :ok
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

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

    assert Repo.get!(StorageFile, reservation.id).status == "processing"
    assert :ok = Storage.write_upload(reservation.id, "# Browser ")
    assert :ok = Storage.write_upload(reservation.id, "report\n")

    assert {:ok, %StorageFile{status: "active"}} =
             Storage.finalize_upload(reservation.id, s3_client: ObjectStore)

    assert_received {:put_file, _bucket, _key, ^content, "text/markdown"}
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
    refute_received {:put_file, _, _, _, _}
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
