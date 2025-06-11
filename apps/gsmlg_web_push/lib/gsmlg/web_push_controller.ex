# lib/push_service_web/controllers/push_controller.ex
defmodule GSMLG.WebPushController do
  @moduledoc """
  Controller for handling web push notifications and subscriptions.

  Add these code to router.ex

  ```elixir
  scope "/api", GSMLG do
    pipe_through([:api, :maybe_api_auth])

    get "/vapid-public-key", WebPushController, :public_key
    post "/subscribe", WebPushController, :subscribe
  end
  scope "/api", GSMLG do
    pipe_through([:api, :maybe_api_auth, :ensure_authed_access])

    post "/send-notification", WebPushController, :send_notification
  end
  ```
  """
  use Phoenix.Controller,
    formats: [:json],
    layouts: []

  import Plug.Conn

  alias GSMLG.WebPush.Subscriptions
  alias GSMLG.WebPush.Vapid

  def public_key(conn, _params) do
    json(conn, %{public_key: Vapid.get_public_key()})
  end

  def subscribe(conn, %{"subscription" => subscription}) do
    case Subscriptions.create_subscription(subscription) do
      {:ok, _subscription} ->
        json(conn, %{status: "success"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset.errors})
    end
  end

  def send_notification(conn, %{"title" => title, "body" => body}) do
    subscriptions = Subscriptions.get_subscriptions()

    Enum.each(subscriptions, fn sub ->
      GSMLG.WebPush.deliver(
        sub.endpoint,
        sub.keys,
        %{title: title, body: body},
        Vapid.get_private_key()
      )
    end)

    json(conn, %{status: "notifications sent"})
  end
end
