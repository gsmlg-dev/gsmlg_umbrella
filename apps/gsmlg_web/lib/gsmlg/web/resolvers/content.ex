defmodule GSMLG.Web.Resolvers.Content do
  def list_blogs(_parent, args, _resolution) when map_size(args) == 0 do
    {:ok, GSMLG.Content.list_blogs()}
  end

  def list_blogs(
        _parent,
        args = %{offset: offset, limit: limit, order_by: order_by},
        _resolution
      )
      when is_integer(limit) and is_binary(order_by) do
    args =
      args
      |> Map.delete(:offset)
      |> Map.delete(:limit)
      |> Map.delete(:order_by)
      |> convert_to_klist()

    order_by =
      order_by
      |> String.split(",")
      |> Enum.map(fn s ->
        s |> String.split(" ") |> Enum.map(fn s -> String.to_atom(s) end) |> List.to_tuple()
      end)

    {:ok, GSMLG.Content.list_blogs_limit(convert_to_klist(args), limit, offset, order_by)}
  end

  def list_blogs(
        _parent,
        args = %{offset: offset, limit: limit},
        _resolution
      )
      when is_integer(limit) do
    args = args |> Map.delete(:offset) |> Map.delete(:limit) |> convert_to_klist()

    {:ok, GSMLG.Content.list_blogs_limit(convert_to_klist(args), limit, offset, [])}
  end

  def list_blogs(_parent, args, _resolution) do
    {:ok, GSMLG.Content.list_blogs(convert_to_klist(args))}
  end

  def find_blog(_parent, %{id: id}, _resolution) do
    {:ok, GSMLG.Content.get_blog!(id)}
  end

  def find_blog(_parent, %{slug: slug}, _resolution) do
    {:ok, GSMLG.Content.get_blog_by_slug(slug)}
  end

  def blogs_info(_parent, _args, _resolution) do
    count = GSMLG.Content.count_blogs()
    last_modified = GSMLG.Content.last_updated_at()
    {:ok, %{total: count, last_modified: last_modified}}
  end

  def convert_to_klist(map) do
    Enum.map(map, fn {key, value} ->
      {key, value}
    end)
  end
end
