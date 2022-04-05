defmodule GSMLGWeb.Schema.ContentTypes do
  use Absinthe.Schema.Notation
  import_types(Absinthe.Type.Custom)

  object :blog do
    field(:id, :id)
    field(:slug, :string)
    field(:author, :string)
    field(:content, :string)
    field(:date, :date)
    field(:title, :string)
  end

  object :blogs_info do
    field(:total, :integer)
    field(:last_modified, :naive_datetime)
  end
end
