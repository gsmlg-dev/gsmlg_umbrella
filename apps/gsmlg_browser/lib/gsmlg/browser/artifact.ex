defmodule GSMLG.Browser.Artifact do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @kinds ~w(report.markdown report.html report.json sources.json observation.json screenshot.png download failure-diagnostic.json)
  @transfer_modes ~w(inline signed_upload remote_pending)
  @statuses ~w(pending uploading verified rejected)
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @filename ~r/\A[^\x00\/\\]+\z/u

  schema "browser_artifacts" do
    field(:job_id, :binary_id)
    field(:session_id, :binary_id)
    field(:kind, :string)
    field(:mime, :string)
    field(:filename, :string)
    field(:size, :integer)
    field(:sha256, :string)
    field(:transfer_mode, :string)
    field(:status, :string, default: "pending")
    field(:storage_type, :string)
    field(:storage_ref, :binary_id)
    field(:inline_content, :binary)
    field(:metadata, :map, default: %{})
    field(:upload_token_digest, :binary, redact: true)
    field(:upload_expires_at, :utc_datetime_usec)
    field(:verified_at, :utc_datetime_usec)
    field(:rejected_at, :utc_datetime_usec)
    field(:ack_status, :string, default: "not_ready")
    field(:ack_attempts, :integer, default: 0)
    field(:acked_at, :utc_datetime_usec)

    timestamps()
  end

  def manifest_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :id,
      :job_id,
      :session_id,
      :kind,
      :mime,
      :filename,
      :size,
      :sha256,
      :transfer_mode,
      :status,
      :storage_type,
      :storage_ref,
      :inline_content,
      :metadata,
      :upload_token_digest,
      :upload_expires_at,
      :verified_at,
      :rejected_at,
      :ack_status,
      :ack_attempts,
      :acked_at
    ])
    |> validate_required([
      :kind,
      :mime,
      :filename,
      :size,
      :sha256,
      :transfer_mode,
      :status
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:transfer_mode, @transfer_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:ack_status, ~w(not_ready pending acked))
    |> validate_number(:ack_attempts, greater_than_or_equal_to: 0)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_format(:sha256, @sha256)
    |> validate_length(:mime, min: 1, max: 255)
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_format(:filename, @filename)
    |> validate_owner()
    |> validate_artifact_type()
    |> GSMLG.Browser.Sanitizer.validate_changeset(metadata: 16_384)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:job_id, name: :browser_artifacts_exactly_one_owner_check)
  end

  def verification_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :status,
      :storage_type,
      :storage_ref,
      :inline_content,
      :verified_at,
      :rejected_at,
      :upload_token_digest,
      :upload_expires_at,
      :ack_status,
      :ack_attempts,
      :acked_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_owner(changeset) do
    case {get_field(changeset, :job_id), get_field(changeset, :session_id)} do
      {job_id, nil} when is_binary(job_id) -> changeset
      {nil, session_id} when is_binary(session_id) -> changeset
      _invalid -> add_error(changeset, :job_id, "must set exactly one artifact owner")
    end
  end

  defp validate_artifact_type(changeset) do
    case GSMLG.Browser.ArtifactPolicy.validate_type(
           get_field(changeset, :kind),
           get_field(changeset, :mime),
           get_field(changeset, :filename)
         ) do
      :ok ->
        changeset

      {:error, _reason} ->
        add_error(changeset, :mime, "does not match artifact kind and filename")
    end
  end
end
