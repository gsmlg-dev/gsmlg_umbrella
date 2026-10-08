defmodule GSMLG.GaoNote.Compat.HTTP do
  @moduledoc false

  def post_json(url, headers, payload, max_bytes) do
    request = Finch.build(:post, url, headers, Jason.encode!(payload))

    case Finch.stream(
           request,
           GSMLG.Finch,
           %{status: nil, bytes: 0, chunks: []},
           fn
             {:status, status}, state ->
               %{state | status: status}

             {:headers, _}, state ->
               state

             {:data, chunk}, state ->
               bytes = state.bytes + byte_size(chunk)
               if bytes > max_bytes, do: throw(:response_limit)
               %{state | bytes: bytes, chunks: [chunk | state.chunks]}
           end,
           receive_timeout: 15_000
         ) do
      {:ok, state} ->
        {:ok,
         %{status: state.status, body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:error, _} ->
        {:error, :service_unavailable}
    end
  catch
    :response_limit -> {:error, :response_limit}
  end
end
