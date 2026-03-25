defmodule GSMLG.Storage.StorageFile do
  @moduledoc """
  Ecto schema for the storage_files table.
  Represents an uploaded file with its metadata, S3 location, and variants.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "storage_files" do
    field(:tenant, :string)
    field(:type, :string)
    field(:filename, :string)
    field(:s3_key, :string)
    field(:content_type, :string)
    field(:size, :integer)
    field(:checksum, :string)
    field(:metadata, :map, default: %{})
    field(:variants, :map, default: %{})
    field(:status, :string, default: "active")
    field(:uploaded_by, :string)

    timestamps()
  end

  @required_fields ~w(tenant type filename s3_key content_type size)a
  @optional_fields ~w(checksum metadata variants status uploaded_by)a

  @safe_path_segment ~r/^[a-z0-9_\-]+$/i

  def changeset(file, attrs) do
    file
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:tenant, @safe_path_segment, message: "only letters, numbers, - and _")
    |> validate_format(:type, @safe_path_segment, message: "only letters, numbers, - and _")
    |> validate_inclusion(:status, ~w(active processing deleted))
    |> validate_number(:size, greater_than: 0)
    |> unique_constraint(:s3_key)
  end

  def status_changeset(file, attrs) do
    file
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ~w(active processing deleted))
  end

  def variants_changeset(file, attrs) do
    file
    |> cast(attrs, [:variants])
  end
end
