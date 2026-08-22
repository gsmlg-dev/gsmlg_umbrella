defmodule GSMLG.Web.OpenApi.WebPushOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/vapid-public-key" => %{"get" => public_key()},
      "/api/subscribe" => %{"post" => subscribe()},
      "/api/send-notification" => %{"post" => send_notification()}
    }
  end

  defp public_key do
    Operation.operation(
      "getVapidPublicKey",
      "Web Push",
      "Get the VAPID public key",
      %{"200" => Operation.json_response("VAPID public key", "VapidKeyEnvelope")},
      security: Operation.anonymous_or_bearer()
    )
  end

  defp subscribe do
    Operation.operation(
      "subscribeWebPush",
      "Web Push",
      "Subscribe a browser for web push notifications",
      %{
        "200" => Operation.json_response("Subscription stored", "StatusEnvelope"),
        "422" => Operation.json_response("Subscription rejected", "SubscriptionError")
      },
      description:
        "The documented request shape is for clients; the server does not enforce this schema.",
      request_body:
        Operation.request_body("WebPushSubscriptionInput", "Browser push subscription"),
      security: Operation.anonymous_or_bearer()
    )
  end

  defp send_notification do
    Operation.operation(
      "sendWebPushNotification",
      "Web Push",
      "Dispatch a web push notification",
      %{
        "200" => Operation.json_response("Notification dispatch attempted", "StatusEnvelope"),
        "401" => Operation.json_response("Authentication required", "AuthError")
      },
      description: "A notification dispatch attempted response does not guarantee delivery.",
      request_body: Operation.request_body("NotificationInput", "Notification content"),
      security: Operation.bearer()
    )
  end
end
