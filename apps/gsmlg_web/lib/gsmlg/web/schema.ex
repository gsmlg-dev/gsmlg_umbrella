defmodule GSMLG.Web.Schema do
  use Absinthe.Schema
  import_types(Absinthe.Plug.Types)
  import_types(GSMLG.Web.Schema.ContentTypes)
  import_types(GSMLG.Web.Schema.NodeTypes)
  import_types(GSMLG.Web.Schema.ChessTypes)

  alias GSMLG.Web.Resolvers

  query do
    @desc "Get all blogs"
    field :blogs, list_of(:blog) do
      arg(:author, :string)
      arg(:date, :date)
      arg(:slug, :string)
      arg(:title, :string)
      arg(:offset, :integer)
      arg(:limit, :integer)
      arg(:order_by, :string)
      resolve(&Resolvers.Content.list_blogs/3)
    end

    @desc "Get one blog by id or slug"
    field :blog, :blog do
      arg(:id, :id)
      arg(:slug, :string)
      resolve(&Resolvers.Content.find_blog/3)
    end

    @desc "Get blogs count"
    field :blogs_info, :blogs_info do
      resolve(&Resolvers.Content.blogs_info/3)
    end

    @desc "Get all nodes"
    field :nodes, list_of(:node) do
      resolve(&Resolvers.Node.list_nodes/3)
    end

    @desc "Get chess"
    field :chess, :chess do
      resolve(&Resolvers.Chess.get_chess/3)
    end

    @desc "Get all chess piece"
    field :pieces, list_of(:piece) do
      resolve(&Resolvers.Chess.list_pieces/3)
    end
  end

  mutation do
    field :start_chess, :chess do
      arg(:started, non_null(:boolean))

      resolve(&Resolvers.Chess.start_chess/3)
    end
  end
end
