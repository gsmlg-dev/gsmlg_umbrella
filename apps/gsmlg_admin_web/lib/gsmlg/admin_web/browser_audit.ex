defmodule GSMLG.AdminWeb.BrowserAudit do
  @moduledoc false

  import Plug.Conn, only: [get_resp_header: 2]

  @allowed_keys ~w(actor_id operation resource_type resource_id outcome error_code request_id)a
  @max_value_bytes 200

  def record(conn, operation, outcome, metadata \\ %{}) do
    base = %{
      actor_id: actor_id(conn.assigns[:actor]),
      operation: operation,
      outcome: outcome,
      request_id: request_id(conn)
    }

    safe_metadata =
      metadata
      |> Map.take(@allowed_keys)
      |> Map.merge(base)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case safe_scalar(value) do
          nil -> acc
          safe -> Map.put(acc, key, safe)
        end
      end)

    GSMLG.Telemetry.Logger.audit("browser_api", safe_metadata)
  end

  defp actor_id(%{id: id}), do: safe_scalar(id)
  defp actor_id(_actor), do: nil

  defp request_id(conn) do
    conn
    |> get_resp_header("x-request-id")
    |> List.first()
  end

  defp safe_scalar(value) when is_atom(value), do: value |> Atom.to_string() |> safe_scalar()
  defp safe_scalar(value) when is_integer(value) or is_boolean(value), do: value

  defp safe_scalar(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "?")
      |> truncate_bytes(@max_value_bytes)
    end
  end

  defp safe_scalar(_value), do: nil

  defp truncate_bytes(value, max) when byte_size(value) <= max, do: value

  defp truncate_bytes(value, max) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= max,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end
end
