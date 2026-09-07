defmodule GSMLG.Commander.RequestDedupTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.Protocol.{RPCRequest, RPCResponse}
  alias GSMLG.Commander.RequestDedup

  test "replays a completed request without executing it twice" do
    dedup = start_supervised!({RequestDedup, name: nil})
    request = request()
    response = response(request.request_id)

    assert :execute = RequestDedup.claim(dedup, request)
    assert :ok = RequestDedup.complete(dedup, request, response)
    assert {:replay, ^response} = RequestDedup.claim(dedup, request)

    retried = %{request | request_id: "00000000-0000-0000-0000-000000000003"}
    assert {:replay, ^response} = RequestDedup.claim(dedup, retried)
  end

  test "rejects reuse of a request or idempotency key for a different payload" do
    dedup = start_supervised!({RequestDedup, name: nil})
    request = request()

    assert :execute = RequestDedup.claim(dedup, request)

    assert {:error, :request_payload_collision} =
             RequestDedup.claim(dedup, %{request | payload: %{"secret" => "changed"}})

    retried = %{
      request
      | request_id: "00000000-0000-0000-0000-000000000003",
        payload: %{"secret" => "changed"}
    }

    assert {:error, :idempotency_payload_collision} = RequestDedup.claim(dedup, retried)
  end

  test "reports an in-progress duplicate instead of running it again" do
    dedup = start_supervised!({RequestDedup, name: nil})
    request = request()
    request_id = request.request_id

    assert :execute = RequestDedup.claim(dedup, request)
    assert {:in_progress, ^request_id} = RequestDedup.claim(dedup, request)
  end

  test "request id collision includes a changed idempotency key" do
    dedup = start_supervised!({RequestDedup, name: nil})
    request = request()

    assert :execute = RequestDedup.claim(dedup, request)

    assert {:error, :request_payload_collision} =
             RequestDedup.claim(dedup, %{request | idempotency_key: "different-key"})
  end

  test "expires old entries and bounds completed request storage" do
    dedup = start_supervised!({RequestDedup, name: nil, ttl_ms: 15, max_entries: 2})
    first = request()
    second = request("00000000-0000-0000-0000-000000000002", "second")
    third = request("00000000-0000-0000-0000-000000000003", "third")

    for item <- [first, second, third] do
      assert :execute = RequestDedup.claim(dedup, item)
      assert :ok = RequestDedup.complete(dedup, item, response(item.request_id))
    end

    assert :execute = RequestDedup.claim(dedup, first)
    Process.sleep(20)
    assert :execute = RequestDedup.claim(dedup, second)
  end

  defp request(
         request_id \\ "00000000-0000-0000-0000-000000000001",
         idempotency_key \\ "manager-status-1"
       ) do
    %RPCRequest{
      protocol_version: 1,
      request_id: request_id,
      capability: "browser.control",
      capability_version: 1,
      operation: "manager.status",
      idempotency_key: idempotency_key,
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: %{"secret" => "not-for-telemetry"}
    }
  end

  defp response(request_id) do
    %RPCResponse{protocol_version: 1, request_id: request_id, result: %{"status" => "ok"}}
  end
end
