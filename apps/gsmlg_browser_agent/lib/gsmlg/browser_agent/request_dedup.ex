defmodule GSMLG.BrowserAgent.RequestDedup do
  @moduledoc "Persistent Browser Agent request and idempotency-key deduplication."

  alias GSMLG.BrowserAgent.Journal
  alias GSMLG.Commander.Protocol.RPCRequest

  def begin_generation(journal \\ Journal), do: Journal.begin_request_generation(journal)

  def claim(journal, %RPCRequest{} = request, generation) when is_binary(generation) do
    Journal.request_claim(
      journal,
      request.request_id,
      request.idempotency_key,
      fingerprint(request),
      request_context(request),
      generation
    )
  end

  def complete(journal \\ Journal, %RPCRequest{} = request, result) do
    complete(journal, request, result, request.request_id)
  end

  def complete(journal, %RPCRequest{} = request, result, request_id) when is_binary(request_id) do
    Journal.request_complete(journal, request_id, fingerprint(request), result)
  end

  def defer(journal \\ Journal, %RPCRequest{} = request) do
    defer(journal, request, request.request_id)
  end

  def defer(journal, %RPCRequest{} = request, request_id) when is_binary(request_id) do
    Journal.request_defer(journal, request_id, fingerprint(request))
  end

  defp fingerprint(request) do
    request
    |> Map.take([:capability, :capability_version, :operation, :idempotency_key, :payload])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp request_context(request) do
    context =
      Map.take(request, [
        :capability,
        :capability_version,
        :operation,
        :idempotency_key,
        :payload
      ])

    if request.operation == "artifact.upload",
      do:
        put_in(
          context,
          [:payload],
          Map.drop(request.payload, ["upload_url", "required_headers"])
        ),
      else: context
  end
end
