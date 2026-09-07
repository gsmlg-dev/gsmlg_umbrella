defmodule GSMLG.Commander.Protocol.TLSSummary do
  @moduledoc "Closed, content-free TLS metadata advertised on Commander heartbeats."

  @certificate_statuses ~w(verified expired not_yet_valid)
  @connection_statuses ~w(server_verified plaintext invalid)

  @spec validate(term()) :: {:ok, map()} | {:error, :invalid_tls_summary}
  def validate(
        %{
          "status" => status,
          "certificate_expires_at" => expires_at
        } = summary
      )
      when status in @certificate_statuses and map_size(summary) == 2 and
             is_binary(expires_at) and byte_size(expires_at) <= 32 do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, 0} ->
        if DateTime.to_iso8601(datetime) == expires_at,
          do: {:ok, summary},
          else: {:error, :invalid_tls_summary}

      _invalid ->
        {:error, :invalid_tls_summary}
    end
  end

  def validate(%{"status" => status} = summary)
      when status in @connection_statuses and map_size(summary) == 1,
      do: {:ok, summary}

  def validate(_summary), do: {:error, :invalid_tls_summary}
end
