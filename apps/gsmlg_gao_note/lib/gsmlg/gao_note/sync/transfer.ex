defmodule GSMLG.GaoNote.Sync.Transfer do
  @moduledoc "One bounded, file-backed sync transfer. The owner must clean up on every exit."
  alias GSMLG.GaoNote.Sync.Protocol
  @maximum 536_870_912
  @error {:error, :validation_failed}

  def begin(payload, limit), do: begin(payload, limit, System.tmp_dir!())

  def begin(payload, limit, staging_root) do
    with true <- Protocol.exact_keys?(payload, ~w(transfer_id size_bytes checksum_sha256)),
         true <- Protocol.uuid?(payload["transfer_id"]),
         true <- is_integer(limit) and limit > 0 and limit <= @maximum,
         true <-
           is_integer(payload["size_bytes"]) and payload["size_bytes"] > 0 and
             payload["size_bytes"] <= limit,
         true <- Protocol.checksum?(payload["checksum_sha256"]) do
      directory =
        Path.join(
          staging_root,
          "gaonote-sync-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        )

      with :ok <- File.mkdir_p(staging_root),
           :ok <- File.mkdir(directory),
           :ok <- File.chmod(directory, 0o700),
           {:ok, blob} <-
             new_blob(directory, "event", payload["size_bytes"], payload["checksum_sha256"]) do
        {:ok,
         %{
           id: payload["transfer_id"],
           directory: directory,
           limit: limit,
           event_size: payload["size_bytes"],
           event: nil,
           active: "event",
           blobs: %{"event" => blob}
         }}
      else
        {:error, reason} ->
          File.rm_rf(directory)
          {:error, {:storage, reason}}
      end
    else
      _ -> @error
    end
  end

  def attachment_begin(state, payload) do
    with true <- Protocol.exact_keys?(payload, ~w(transfer_id blob_id)),
         true <-
           payload["transfer_id"] == state.id and is_nil(state.active) and not is_nil(state.event),
         "attachment:" <> id <- payload["blob_id"],
         false <- Map.has_key?(state.blobs, payload["blob_id"]),
         descriptor when is_map(descriptor) <-
           Enum.find(attachments(state.event), &(&1["id"] == id)),
         {:ok, blob} <-
           new_blob(
             state.directory,
             payload["blob_id"],
             descriptor["size_bytes"],
             descriptor["checksum_sha256"]
           ) do
      {:ok,
       %{
         state
         | active: payload["blob_id"],
           blobs: Map.put(state.blobs, payload["blob_id"], blob)
       }}
    else
      {:error, reason} -> {:error, {:storage, reason}}
      _ -> @error
    end
  end

  def chunk(state, payload) do
    with true <- Protocol.exact_keys?(payload, ~w(transfer_id blob_id offset data)),
         true <- payload["transfer_id"] == state.id and payload["blob_id"] == state.active,
         blob when is_map(blob) <- Map.get(state.blobs, state.active),
         true <- is_integer(payload["offset"]) and payload["offset"] == blob.received,
         true <- is_binary(payload["data"]) and byte_size(payload["data"]) <= 87_384,
         {:ok, bytes} <- Base.decode64(payload["data"], padding: true),
         true <- Base.encode64(bytes) == payload["data"] and byte_size(bytes) <= 65_536,
         true <- blob.received + byte_size(bytes) <= blob.size,
         :ok <- File.write(blob.path, bytes, [:append, :binary]) do
      blob = %{
        blob
        | received: blob.received + byte_size(bytes),
          hash: :crypto.hash_update(blob.hash, bytes)
      }

      {:ok, %{state | blobs: Map.put(state.blobs, state.active, blob)}}
    else
      {:error, :invalid} -> @error
      {:error, reason} -> {:error, {:storage, reason}}
      _ -> @error
    end
  end

  def blob_end(state, payload) do
    with true <- Protocol.exact_keys?(payload, ~w(transfer_id blob_id)),
         true <- payload["transfer_id"] == state.id and payload["blob_id"] == state.active,
         blob when is_map(blob) <- Map.get(state.blobs, state.active),
         true <-
           blob.received == blob.size and
             Base.encode16(:crypto.hash_final(blob.hash), case: :lower) == blob.checksum,
         {:ok, event} <- decode_event(state, blob) do
      {:ok,
       %{
         state
         | event: event,
           active: nil,
           blobs: Map.put(state.blobs, state.active, %{blob | complete: true})
       }}
    else
      {:error, _} = error -> error
      _ -> @error
    end
  end

  def commit(state, payload) do
    with true <- Protocol.exact_keys?(payload, ~w(transfer_id)),
         true <-
           payload["transfer_id"] == state.id and is_nil(state.active) and is_map(state.event),
         true <-
           Enum.all?(attachments(state.event), fn a ->
             match?(%{complete: true}, state.blobs["attachment:" <> a["id"]])
           end) do
      Enum.reduce_while(attachments(state.event), {:ok, %{}}, fn a, {:ok, objects} ->
        case File.read(state.blobs["attachment:" <> a["id"]].path) do
          {:ok, bytes} -> {:cont, {:ok, Map.put(objects, a["id"], bytes)}}
          {:error, reason} -> {:halt, {:error, {:storage, reason}}}
        end
      end)
      |> case do
        {:ok, objects} -> {:ok, state.event, objects}
        error -> error
      end
    else
      _ -> @error
    end
  end

  def cleanup(nil), do: :ok

  def cleanup(%{directory: directory}) do
    case File.rm_rf(directory) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:storage, reason}}
    end
  end

  defp decode_event(%{active: "event"} = state, blob) do
    with {:ok, bytes} <- File.read(blob.path),
         {:ok, event} <- Jason.decode(bytes),
         :ok <- Protocol.validate_event(event),
         true <-
           Enum.reduce(attachments(event), state.event_size, &(&1["size_bytes"] + &2)) <=
             state.limit do
      {:ok, event}
    else
      {:error, %Jason.DecodeError{}} -> @error
      {:error, :validation_failed} -> @error
      {:error, reason} -> {:error, {:storage, reason}}
      _ -> @error
    end
  end

  defp decode_event(state, _blob), do: {:ok, state.event}
  defp attachments(%{"snapshot" => nil}), do: []
  defp attachments(event), do: event["snapshot"]["attachments"]

  defp new_blob(directory, id, size, checksum) do
    path = Path.join(directory, Protocol.sha256(id))

    with :ok <- File.write(path, "", [:exclusive, :binary]) do
      {:ok,
       %{
         path: path,
         size: size,
         received: 0,
         checksum: checksum,
         hash: :crypto.hash_init(:sha256),
         complete: false
       }}
    end
  end
end
