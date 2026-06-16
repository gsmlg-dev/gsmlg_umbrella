defmodule GSMLG.GaoNote.Asset do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.Note
  alias GSMLG.Storage.StorageFile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @roles ~w(attachment cover inline source)

  schema "gao_note_assets" do
    belongs_to(:note, Note)
    belongs_to(:storage_file, StorageFile)

    field(:role, :string, default: "attachment")
    field(:caption, :string)
    field(:alt_text, :string)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def roles, do: @roles

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:note_id, :storage_file_id, :role, :caption, :alt_text, :position, :metadata])
    |> validate_required([:note_id, :storage_file_id])
    |> validate_inclusion(:role, @roles)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:note_id, :storage_file_id])
  end
end
