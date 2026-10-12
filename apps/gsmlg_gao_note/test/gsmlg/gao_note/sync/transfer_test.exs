defmodule GSMLG.GaoNote.Sync.TransferTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.Sync.{Protocol, Transfer}
  alias GSMLG.GaoNote.Sync.ProtocolTest
  @id "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

  defp begin_transfer(event, limit \\ 1_000_000) do
    bytes = Jason.encode!(event)

    {:ok, transfer} =
      Transfer.begin(
        %{
          "transfer_id" => @id,
          "size_bytes" => byte_size(bytes),
          "checksum_sha256" => Protocol.sha256(bytes)
        },
        limit
      )

    on_exit(fn -> Transfer.cleanup(transfer) end)
    {transfer, bytes}
  end

  defp chunk(transfer, blob, offset, bytes),
    do:
      Transfer.chunk(transfer, %{
        "transfer_id" => @id,
        "blob_id" => blob,
        "offset" => offset,
        "data" => Base.encode64(bytes)
      })

  defp finish(transfer, blob),
    do: Transfer.blob_end(transfer, %{"transfer_id" => @id, "blob_id" => blob})

  test "verifies exact event bytes and zero-byte manifest object before commit" do
    event = ProtocolTest.event()
    {transfer, bytes} = begin_transfer(event)
    assert {:ok, transfer} = chunk(transfer, "event", 0, bytes)
    assert {:ok, transfer} = finish(transfer, "event")
    blob = "attachment:" <> hd(event["snapshot"]["attachments"])["id"]
    assert {:error, :validation_failed} = Transfer.commit(transfer, %{"transfer_id" => @id})

    assert {:ok, transfer} =
             Transfer.attachment_begin(transfer, %{"transfer_id" => @id, "blob_id" => blob})

    assert {:ok, transfer} = finish(transfer, blob)
    assert {:ok, ^event, objects} = Transfer.commit(transfer, %{"transfer_id" => @id})
    assert Map.values(objects) == [""]
    assert :ok = Transfer.cleanup(transfer)
    refute File.exists?(transfer.directory)
  end

  test "rejects skipped offsets unpadded base64 oversize chunks and corrupt hash" do
    {transfer, bytes} = begin_transfer(ProtocolTest.event())
    assert {:error, :validation_failed} = chunk(transfer, "event", 1, bytes)
    assert {:error, :validation_failed} = chunk(transfer, "event", 0, :binary.copy("a", 65_537))

    assert {:error, :validation_failed} =
             Transfer.chunk(transfer, %{
               "transfer_id" => @id,
               "blob_id" => "event",
               "offset" => 0,
               "data" => "YQ"
             })

    assert {:ok, transfer} = chunk(transfer, "event", 0, String.duplicate("x", byte_size(bytes)))
    assert {:error, :validation_failed} = finish(transfer, "event")
  end

  test "native attachment ID event remains distinct from metadata and verifies multiple chunks" do
    content = :binary.copy("x", 65_540)
    event = ProtocolTest.event()

    attachment = %{
      "id" => "event",
      "path" => "assets/data.bin",
      "mime" => "application/octet-stream",
      "description" => "",
      "size_bytes" => byte_size(content),
      "checksum_sha256" => Protocol.sha256(content)
    }

    event = put_in(event, ["snapshot", "attachments"], [attachment])
    event = Map.put(event, "snapshot_hash", Protocol.snapshot_hash(event["snapshot"]))
    {transfer, bytes} = begin_transfer(event)
    {:ok, transfer} = chunk(transfer, "event", 0, bytes)
    {:ok, transfer} = finish(transfer, "event")
    assert {:error, :validation_failed} = finish(transfer, "event")

    {:ok, transfer} =
      Transfer.attachment_begin(transfer, %{"transfer_id" => @id, "blob_id" => "attachment:event"})

    {:ok, transfer} = chunk(transfer, "attachment:event", 0, binary_part(content, 0, 65_536))
    assert {:error, :validation_failed} = finish(transfer, "attachment:event")
    {:ok, transfer} = chunk(transfer, "attachment:event", 65_536, binary_part(content, 65_536, 4))
    {:ok, transfer} = finish(transfer, "attachment:event")

    assert {:error, :validation_failed} =
             Transfer.attachment_begin(transfer, %{
               "transfer_id" => @id,
               "blob_id" => "attachment:event"
             })

    assert {:ok, ^event, %{"event" => ^content}} =
             Transfer.commit(transfer, %{"transfer_id" => @id})
  end

  test "aggregate includes manifest objects and rejects undeclared or duplicate blob" do
    event = ProtocolTest.event()
    event = put_in(event, ["snapshot", "attachments", Access.at(0), "size_bytes"], 1_000_000)
    event = Map.put(event, "snapshot_hash", Protocol.snapshot_hash(event["snapshot"]))
    {transfer, bytes} = begin_transfer(event)
    assert {:ok, transfer} = chunk(transfer, "event", 0, bytes)
    assert {:error, :validation_failed} = finish(transfer, "event")

    assert {:error, :validation_failed} =
             Transfer.attachment_begin(transfer, %{
               "transfer_id" => @id,
               "blob_id" => "attachment:unknown"
             })
  end
end
