defmodule GSMLG.Commander.Protocol.ArtifactManifest do
  @moduledoc "A strict integrity and ownership manifest for one Browser artifact."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [
    :protocol_version,
    :artifact_id,
    :kind,
    :mime,
    :filename,
    :size,
    :sha256,
    :transfer_mode,
    :metadata
  ]
  defstruct @enforce_keys ++ [:job_id, :session_id]

  @required_fields ~w(type protocol_version artifact_id kind mime filename size sha256 transfer_mode metadata)
  @owner_fields ~w(job_id session_id)
  @kinds ~w(report.markdown report.html report.json sources.json observation.json screenshot.png download failure-diagnostic.json)
  @transfer_modes ~w(inline signed_upload remote_pending)
  @filename ~r/\A[^\x00\/\\]+\z/u
  @media %{
    "report.markdown" => {"text/markdown", ".md"},
    "report.html" => {"text/html", ".html"},
    "report.json" => {"application/json", ".json"},
    "sources.json" => {"application/json", ".json"},
    "observation.json" => {"application/json", ".json"},
    "screenshot.png" => {"image/png", ".png"},
    "download" => [
      {"application/octet-stream", ".bin"},
      {"application/pdf", ".pdf"},
      {"application/json", ".json"},
      {"text/html", ".html"},
      {"text/markdown", ".md"},
      {"text/plain", ".txt"},
      {"image/png", ".png"},
      {"image/jpeg", ".jpg"},
      {"image/jpeg", ".jpeg"}
    ],
    "failure-diagnostic.json" => {"application/json", ".json"}
  }
  @max_metadata_entries 16
  @max_metadata_bytes 4_096

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          artifact_id: String.t(),
          job_id: String.t() | nil,
          session_id: String.t() | nil,
          kind: String.t(),
          mime: String.t(),
          filename: String.t(),
          size: non_neg_integer(),
          sha256: String.t(),
          transfer_mode: String.t(),
          metadata: map()
        }

  @spec decode(map()) :: {:ok, t()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(map) when is_map(map) do
    with :ok <- Validation.fields(map, @required_fields, @owner_fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["artifact_id"], "artifact_id"),
         :ok <- valid_owner(map),
         :ok <- Validation.one_of(map["kind"], @kinds, "kind"),
         :ok <- Validation.bounded_string(map["mime"], "mime", 255),
         :ok <- valid_filename(map["filename"]),
         :ok <- valid_media(map["kind"], map["mime"], map["filename"]),
         :ok <- Validation.nonnegative_integer(map["size"], "size"),
         :ok <- Validation.sha256(map["sha256"], "sha256"),
         :ok <- Validation.one_of(map["transfer_mode"], @transfer_modes, "transfer_mode"),
         :ok <- valid_metadata(map["metadata"]) do
      {:ok,
       struct!(__MODULE__,
         protocol_version: map["protocol_version"],
         artifact_id: map["artifact_id"],
         job_id: map["job_id"],
         session_id: map["session_id"],
         kind: map["kind"],
         mime: map["mime"],
         filename: map["filename"],
         size: map["size"],
         sha256: map["sha256"],
         transfer_mode: map["transfer_mode"],
         metadata: map["metadata"]
       )}
    end
  end

  def decode(_invalid), do: Validation.invalid("invalid_artifact_manifest", %{})

  @spec encode(t()) :: {:ok, map()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def encode(%__MODULE__{} = manifest) do
    wire =
      %{
        "type" => "artifact.manifest",
        "protocol_version" => manifest.protocol_version,
        "artifact_id" => manifest.artifact_id,
        "kind" => manifest.kind,
        "mime" => manifest.mime,
        "filename" => manifest.filename,
        "size" => manifest.size,
        "sha256" => manifest.sha256,
        "transfer_mode" => manifest.transfer_mode,
        "metadata" => manifest.metadata
      }
      |> put_owner(manifest)

    with {:ok, _manifest} <- decode(wire), do: {:ok, wire}
  end

  def encode(_invalid), do: Validation.invalid("invalid_artifact_manifest", %{})

  @doc "Validates the protocol's finite artifact kind, MIME, and filename-extension contract."
  @spec validate_media(term(), term(), term()) ::
          :ok | {:error, GSMLG.Commander.Protocol.Error.t()}
  def validate_media(kind, mime, filename)
      when is_binary(kind) and is_binary(mime) and is_binary(filename),
      do: valid_media(kind, mime, filename)

  def validate_media(_kind, _mime, _filename),
    do: Validation.invalid("invalid_artifact_media", %{})

  defp valid_owner(%{"job_id" => job_id} = map) when not is_map_key(map, "session_id"),
    do: Validation.uuid(job_id, "job_id")

  defp valid_owner(%{"session_id" => session_id} = map) when not is_map_key(map, "job_id"),
    do: Validation.uuid(session_id, "session_id")

  defp valid_owner(_map), do: Validation.invalid("invalid_artifact_owner", %{})

  defp put_owner(wire, %{job_id: job_id, session_id: nil}) when is_binary(job_id),
    do: Map.put(wire, "job_id", job_id)

  defp put_owner(wire, %{job_id: nil, session_id: session_id}) when is_binary(session_id),
    do: Map.put(wire, "session_id", session_id)

  defp put_owner(wire, _manifest), do: wire

  defp valid_filename(filename) when is_binary(filename) do
    cond do
      byte_size(filename) not in 1..255 ->
        Validation.invalid("invalid_filename", %{})

      filename in [".", ".."] or not Regex.match?(@filename, filename) ->
        Validation.invalid("invalid_filename", %{})

      true ->
        :ok
    end
  end

  defp valid_filename(_filename), do: Validation.invalid("invalid_filename", %{})

  defp valid_media(kind, mime, filename) do
    case Map.fetch(@media, kind) do
      {:ok, formats} ->
        formats = if is_tuple(formats), do: [formats], else: formats

        if Enum.any?(formats, fn {allowed_mime, extension} ->
             mime == allowed_mime and String.downcase(Path.extname(filename)) == extension
           end),
           do: :ok,
           else: Validation.invalid("invalid_artifact_media", %{})

      _mismatch ->
        Validation.invalid("invalid_artifact_media", %{})
    end
  end

  defp valid_metadata(metadata) when is_map(metadata) do
    with :ok <- Validation.wire_map(metadata, "metadata"),
         {:ok, encoded_size} <- Validation.encoded_size(metadata) do
      if map_size(metadata) <= @max_metadata_entries and encoded_size <= @max_metadata_bytes,
        do: :ok,
        else: Validation.invalid("metadata_too_large", %{})
    end
  end

  defp valid_metadata(_metadata), do: Validation.invalid("invalid_map", %{"field" => "metadata"})
end
