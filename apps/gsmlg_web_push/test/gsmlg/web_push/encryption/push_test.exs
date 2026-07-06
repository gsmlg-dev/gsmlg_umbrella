defmodule GSMLG.WebPush.Encryption.PushTest do
  use ExUnit.Case

  alias GSMLG.WebPush.Encryption.Push

  setup_all do
    {:ok, _pid} = HTTPFetchSandbox.start_link(:ok)
    # Configure the http_client to use our sandbox
    Application.put_env(:gsmlg_web_push, :http_client, HTTPFetchSandbox)

    on_exit(fn ->
      Application.delete_env(:gsmlg_web_push, :http_client)
    end)

    :ok
  end

  setup do
    HTTPFetchSandbox.reset_requests!()
    :ok
  end

  test "normal endpoint with auth_token" do
    assert {:ok, %HTTP.Response{status: 201}} =
             Push.send_web_push(Fixtures.example_input(), Fixtures.valid_subscription())

    assert [%{method: :post}] = HTTPFetchSandbox.requests()
  end

  test "fcm endpoint with auth_token" do
    assert {:ok, %HTTP.Response{status: 201}} =
             Push.send_web_push(
               Fixtures.example_input(),
               Fixtures.valid_fcm_subscription(),
               "auth_token"
             )

    assert [%{method: :post, headers: %{"Authorization" => "key=auth_token"}}] =
             HTTPFetchSandbox.requests()
  end
end
