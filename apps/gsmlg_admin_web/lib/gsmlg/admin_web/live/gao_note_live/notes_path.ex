defmodule GSMLG.AdminWeb.GaoNoteLive.NotesPath do
  use GSMLG.AdminWeb, :verified_routes

  def index(filters \\ %{}) do
    search = filters |> value(:search, "") |> blank_to_nil()
    labels = filters |> value(:labels, []) |> normalize_labels()
    page = value(filters, :page, 1)
    page_size = value(filters, :page_size, nil)

    query =
      []
      |> maybe_put(:search, search)
      |> maybe_put(:labels, labels)
      |> maybe_put(:page, if(is_integer(page) and page > 1, do: page))
      |> maybe_put(:page_size, if(page_size in [10, 25, 50, 100], do: page_size))

    ~p"/gao_notes/notes?#{query}"
  end

  def exact_label(key, value), do: index(%{labels: ["#{key}=#{value}"]})

  defp value(filters, key, default) do
    Map.get(filters, Atom.to_string(key), Map.get(filters, key, default))
  end

  defp normalize_labels(labels) do
    labels
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp maybe_put(query, _key, value) when value in [nil, "", []], do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
