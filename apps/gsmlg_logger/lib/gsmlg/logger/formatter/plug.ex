if Code.ensure_loaded?(Plug) do
  defmodule GSMLG.Logger.Formatter.Plug do
    @moduledoc false

    alias Plug.Conn

    @doc """
    Returns the first IP address from the `x-forwarded-for` header
    if it exists, otherwise returns the remote IP address.

    Please keep in mind that returning first IP address from the
    `x-forwarded-for` header is not very reliable, as it can be
    easily spoofed. Additionally, we do not exclude the IP addresses
    from list of well-known proxies, so it's possible that the
    returned IP address is not the actual client IP address.
    """
    def remote_ip(conn) do
      if header_value = get_ip_from_header(conn) do
        header_value
        |> String.split(",")
        |> hd()
        |> String.trim()
      else
        case conn.remote_ip do
          {:local, local} ->
            "local#{local}"

          remote_ip ->
            remote_ip |> :inet.ntoa() |> to_string()
        end
      end
    end

    @doc """
    Returns the first value of the given header from the request.
    """
    def get_header(conn, header) do
      case Conn.get_req_header(conn, header) do
        [] -> nil
        [val | _] -> val
      end
    end

    defp get_ip_from_header(conn) do
      case Conn.get_req_header(conn, "x-real-ip") do
        [val | _] ->
          val

        [] ->
          case Conn.get_req_header(conn, "x-forwarded-for") do
            [] -> nil
            [val | _] -> val
          end
      end
    end
  end
end
