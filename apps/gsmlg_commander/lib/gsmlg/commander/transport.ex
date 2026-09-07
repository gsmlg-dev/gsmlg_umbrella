defmodule GSMLG.Commander.Transport do
  @moduledoc "Adds freshly generated Commander authentication to every transport open."

  @behaviour Phoenix.SocketClient.Transport

  @default_transport Phoenix.SocketClient.Transports.Websocket

  @impl true
  def open(url, opts) do
    {provider, opts} = Keyword.pop!(opts, :commander_auth_provider)
    {delegate, opts} = Keyword.pop(opts, :delegate_transport, @default_transport)
    opts = put_auth_headers(opts, provider.())

    # WORKAROUND(upstream): gsmlg-dev/http_fetch#12
    # Keep authentication out of URLs until HTTP.WebSocket telemetry redacts URL credentials.
    delegate.open(url, opts)
  end

  @impl true
  def close(socket), do: @default_transport.close(socket)

  defp put_auth_headers(opts, auth) do
    auth_headers = [
      {"x-commander-signature", Map.fetch!(auth, "signature")},
      {"x-commander-name", Map.fetch!(auth, "name")},
      {"x-commander-credential-id", Map.fetch!(auth, "credential_id")},
      {"x-commander-sign-at", Map.fetch!(auth, "sign_at")},
      {"x-commander-nonce", Map.fetch!(auth, "nonce")}
    ]

    auth_header_names = MapSet.new(auth_headers, fn {name, _value} -> name end)
    existing = Keyword.get(opts, :headers, Keyword.get(opts, :extra_headers, []))

    existing =
      Enum.reject(existing, fn {name, _value} ->
        MapSet.member?(auth_header_names, String.downcase(name))
      end)

    opts
    |> Keyword.delete(:extra_headers)
    |> Keyword.put(:headers, existing ++ auth_headers)
  end
end
