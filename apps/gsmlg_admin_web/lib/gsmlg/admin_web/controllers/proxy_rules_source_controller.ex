defmodule GSMLG.AdminWeb.ProxyRulesSourceController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.ProxyRules

  def show(conn, %{"source" => source} = params) do
    with {:ok, source} <- parse_source(source),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, page} <-
           ProxyRules.get_source_page(source, Map.get(params, "cursor"), line_limit: limit) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(page)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp parse_source("gfwlist"), do: {:ok, :remote_gfwlist}
  defp parse_source("local-proxy"), do: {:ok, :local_proxy}
  defp parse_source("local-direct"), do: {:ok, :local_direct}
  defp parse_source(_source), do: {:error, :not_found}

  defp parse_limit(nil), do: {:ok, 200}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} when limit in 1..500 -> {:ok, limit}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_limit), do: {:error, :invalid_limit}

  defp render_error(conn, reason)
       when reason in [
              :not_found,
              :invalid_limit,
              :invalid_cursor,
              :source_changed,
              :not_available,
              :page_too_large
            ] do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status(reason))
    |> json(%{
      error: %{
        code: Atom.to_string(reason),
        message: message(reason)
      }
    })
  end

  defp status(:not_found), do: :not_found
  defp status(:invalid_limit), do: :unprocessable_entity
  defp status(:invalid_cursor), do: :unprocessable_entity
  defp status(:source_changed), do: :conflict
  defp status(:not_available), do: :service_unavailable
  defp status(:page_too_large), do: :unprocessable_entity

  defp message(:not_found), do: "Proxy rule source not found"
  defp message(:invalid_limit), do: "Limit must be an integer from 1 through 500"
  defp message(:invalid_cursor), do: "Cursor is invalid"
  defp message(:source_changed), do: "Source changed; reload it before continuing"
  defp message(:not_available), do: "Proxy rule source service is unavailable"
  defp message(:page_too_large), do: "A source line exceeds the maximum page size"
end
