defmodule GSMLG.AdminWeb.ScoutFetchController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server

  def create(conn, params) do
    case Server.submit_fetch(params) do
      {:ok, job} ->
        conn
        |> put_status(:accepted)
        |> json(Map.take(job, [:job_id, :status]))

      {:error, error} ->
        render_error(conn, error)
    end
  end

  def show(conn, %{"job_id" => job_id}) do
    case Server.get_fetch(job_id) do
      {:ok, job} -> json(conn, job)
      {:error, error} -> render_error(conn, error)
    end
  end

  def sync(conn, params) do
    case Server.fetch_sync(params) do
      {:ok, %Result{} = result} ->
        status = if result.ok, do: :ok, else: :unprocessable_entity

        conn
        |> put_status(status)
        |> json(Result.to_map(result))

      {:error, error} ->
        render_error(conn, error)
    end
  end

  defp render_error(conn, error) do
    conn
    |> put_status(status_for(error))
    |> json(%{error: error})
  end

  defp status_for(%{type: "not_found"}), do: :not_found
  defp status_for(%{type: "invalid_url"}), do: :unprocessable_entity
  defp status_for(%{type: "unsupported_protocol"}), do: :unprocessable_entity
  defp status_for(%{type: "blocked_target"}), do: :unprocessable_entity
  defp status_for(_error), do: :internal_server_error
end
