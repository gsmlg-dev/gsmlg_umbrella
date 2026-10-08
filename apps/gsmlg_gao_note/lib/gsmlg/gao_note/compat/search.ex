defmodule GSMLG.GaoNote.Compat.Search do
  @moduledoc "Search uses the external index; GaoNote never manufactures relevance scores."
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.{LabelSelector, Presenter}

  def search_notes(attrs) when is_map(attrs) do
    query = field(attrs, :query)
    limit = field(attrs, :limit)
    label = field(attrs, :label) || ""

    with true <- is_binary(query) and is_integer(limit) and limit >= 0,
         {:ok, selectors} <- LabelSelector.parse(label),
         {:ok, hits} <- fetch(query, limit, label) do
      minimum = config()[:minimum_score] || 0.01

      hits
      |> Enum.reduce_while({:ok, []}, fn hit, {:ok, results} ->
        case hit do
          %{"id" => id, "score" => score} when is_binary(id) and is_number(score) ->
            note = Compat.get_note(id)

            if note && score >= minimum &&
                 LabelSelector.matches_all?(Presenter.mcp_note(note).labels, selectors) do
              {:cont, {:ok, [%{note: note, score: score} | results]}}
            else
              {:cont, {:ok, results}}
            end

          _ ->
            {:halt, {:error, :search_unavailable}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, results |> Enum.reverse() |> Enum.take(limit)}
        error -> error
      end
    else
      false -> {:error, {:invalid_input, "query and non-negative integer limit are required"}}
      {:error, message} when is_binary(message) -> {:error, {:invalid_input, message}}
      error -> error
    end
  end

  def search_notes(_), do: {:error, {:invalid_input, "search request must be an object"}}

  defp fetch(_query, 0, _label), do: {:ok, []}

  defp fetch(query, limit, label) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      fetch_service(query, limit, label)
    end
  end

  defp fetch_service(query, limit, label) do
    case config()[:search_url] do
      url when is_binary(url) and url != "" ->
        headers = [{"content-type", "application/json"}]
        token = config()[:search_token]

        headers =
          if is_binary(token) and token != "",
            do: [{"authorization", "Bearer #{token}"} | headers],
            else: headers

        case GSMLG.GaoNote.Compat.HTTP.post_json(
               url,
               headers,
               %{query: query, limit: limit, label: label},
               4_194_304
             ) do
          {:ok, %{status: 200, body: body}} when byte_size(body) <= 4_194_304 ->
            case Jason.decode(body) do
              {:ok, hits} when is_list(hits) -> {:ok, hits}
              _ -> {:error, :search_unavailable}
            end

          _ ->
            {:error, :search_unavailable}
        end

      _ ->
        {:error, :search_unavailable}
    end
  end

  def config, do: Application.get_env(:gsmlg_gao_note, :compat_services, [])
  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
