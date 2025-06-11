defmodule GSMLG.WebPush do
  @moduledoc """
  Documentation for `GSMLG.WebPush`.
  """

  @doc """
  Deliver a push notification

  ```javascript
  fetch('/api/send-notification', { method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({ title: 'Hello Kamino', body: 'from client notification' }) })
  ```
  """
  def deliver(endpoint, keys, payload, private_key) do
    payload_json = Jason.encode!(payload)
    subscription = %{keys: keys, endpoint: endpoint}
    # encrypt the body if manually send push
    # _encrypted_body = GSMLG.WebPush.Encryption.encrypt(payload_json, subscription)
    # or just send the push
    GSMLG.WebPush.Encryption.send_web_push(payload_json, subscription, private_key)
    |> IO.inspect()
  end
end
