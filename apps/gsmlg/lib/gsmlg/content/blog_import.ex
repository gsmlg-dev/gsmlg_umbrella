defmodule GSMLG.Content.BlogImport do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Content.BlogImport
  alias GSMLG.Content.Blog
  alias GSMLG.Repo

  embedded_schema do
    field(:data, :string)
  end

  @doc false
  def changeset(%BlogImport{} = blog_import, attrs) do
    blog_import
    |> cast(attrs, [:data])
    |> validate_required([:data])
    |> validate_json_data()
  end

  def import(attrs) do
    changeset(%BlogImport{}, attrs)
    |> do_import()
  end

  defp validate_json_data(%Ecto.Changeset{changes: %{data: data}} = changeset)
       when is_binary(data) do
    case Jason.decode(data) do
      {:ok, _blogs} ->
        changeset

      {:error, %Jason.DecodeError{position: position, token: token, data: _data}} ->
        changeset
        |> add_error(
          :data,
          "Parse JSON error at position:(#{position}), token(#{token})"
        )
    end
  end

  defp validate_json_data(changeset) do
    changeset
  end

  defp do_import(%Ecto.Changeset{changes: %{data: data}} = changeset) do
    case Repo.transaction(fn ->
           Enum.each(Jason.decode!(data), fn blog ->
             %Blog{}
             |> Blog.changeset(blog)
             |> Repo.insert!()
           end)
         end) do
      {:ok, _} ->
        {:ok, changeset}

      {:error, err} ->
        {:error,
         changeset
         |> add_error(
           :data,
           "Error: #{err}"
         )}
    end
  end

  defp do_import(changeset) do
    {:error, changeset}
  end
end
