defmodule GSMLG.GaoNote.Sync.SnapshotReadTest do
  use GSMLG.GaoNote.DataCase, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  alias GSMLG.GaoNote.Sync.Snapshot
  alias GSMLG.Storage.StorageFile

  defmodule ObjectStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/*path" do
      bytes = Application.fetch_env!(:gsmlg_gao_note, :snapshot_test_bytes)
      [range] = get_req_header(conn, "range")
      "bytes=" <> bounds = range
      [first, last] = bounds |> String.split("-") |> Enum.map(&String.to_integer/1)

      send(
        Application.fetch_env!(:gsmlg_gao_note, :snapshot_test_owner),
        {:object_range, first, last}
      )

      if first >= byte_size(bytes) do
        send_resp(conn, 416, "")
      else
        size = min(last + 1, byte_size(bytes)) - first
        send_resp(conn, 206, binary_part(bytes, first, size))
      end
    end
  end

  defmodule SwitchingCatalogClient do
    def get_object(backend, key) do
      result = GSMLG.Storage.TestCatalogClient.get_object(backend, key)
      Application.put_env(:gsmlg_storage, :s3_bucket, "replacement-bucket")
      result
    end
  end

  setup do
    Application.put_env(:gsmlg_gao_note, :snapshot_test_owner, self())
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: ObjectStub, port: port, startup_log: false})

    config = %{
      s3_access_key_id: "test",
      s3_secret_access_key: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_bucket: "snapshot-test"
    }

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      Application.delete_env(:gsmlg_gao_note, :snapshot_test_bytes)
      Application.delete_env(:gsmlg_gao_note, :snapshot_test_owner)
    end)

    :ok
  end

  test "reads multi-chunk objects and verifies a stored checksum" do
    bytes = String.duplicate("a", 4_194_304) <> "final"
    file = insert_file(bytes, hash(bytes))
    assert {:ok, ^bytes} = Snapshot.read_object(file.id)

    assert_receive {:object_range, 0, 4_194_303}
    assert_receive {:object_range, 4_194_304, 4_194_308}
    refute_received {:object_range, _, _}
  end

  test "reads a 10,449,995-byte attachment using three bounded S3 ranges" do
    bytes = :binary.copy("attachment", 1_044_999) <> "final"
    checksum = hash(bytes)
    file = insert_file(bytes, checksum)

    assert byte_size(bytes) == 10_449_995
    assert {:ok, downloaded} = Snapshot.read_object(file.id)
    assert downloaded == bytes
    assert hash(downloaded) == checksum

    assert_receive {:object_range, 0, 4_194_303}
    assert_receive {:object_range, 4_194_304, 8_388_607}
    assert_receive {:object_range, 8_388_608, 10_449_994}
    refute_received {:object_range, _, _}
  end

  test "legacy checksum reads compute SHA256 without trusting obsolete digest metadata" do
    file = insert_file("legacy", "old-md5-checksum")
    assert {:ok, "legacy"} = Snapshot.read_object(file.id)
  end

  test "zero-byte objects complete after a bounded empty range response" do
    file = insert_file("", hash(""))
    assert {:ok, ""} = Snapshot.read_object(file.id)
  end

  test "rejects declared size and checksum mismatches" do
    file = insert_file("data", String.duplicate("a", 64))
    assert {:error, :object_checksum_mismatch} = Snapshot.read_object(file.id)
    Application.put_env(:gsmlg_gao_note, :snapshot_test_bytes, "x")
    assert {:error, :object_size_mismatch} = Snapshot.read_object(file.id)
  end

  test "backend changes after metadata is loaded abort both empty and nonempty object reads" do
    for bytes <- ["", "data"] do
      Application.put_env(:gsmlg_storage, :s3_bucket, "snapshot-test")
      Application.put_env(:gsmlg_storage, :catalog_s3_client, GSMLG.Storage.TestCatalogClient)
      file = insert_file(bytes, hash(bytes))
      Application.put_env(:gsmlg_storage, :catalog_s3_client, SwitchingCatalogClient)
      assert {:error, :backend_changed} = Snapshot.read_object(file.id)
    end
  end

  defp insert_file(bytes, checksum) do
    Application.put_env(:gsmlg_gao_note, :snapshot_test_bytes, bytes)

    %StorageFile{}
    |> StorageFile.changeset(%{
      tenant: "gao_note",
      type: "gao_note_attachment",
      filename: "object.txt",
      s3_key: "snapshot/#{Ecto.UUID.generate()}",
      content_type: "text/plain",
      size: byte_size(bytes),
      checksum: checksum,
      variants: %{}
    })
    |> GSMLG.Storage.TestCatalogClient.insert_file!()
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
