defmodule GSMLG.WebPush.Encryption do
  @moduledoc """
  Facade module to access encryption and push functionalities
  """

  defdelegate send_web_push(message, subscription, auth_token, ttl),
    to: GSMLG.WebPush.Encryption.Push

  defdelegate send_web_push(message, subscription, auth_token), to: GSMLG.WebPush.Encryption.Push
  defdelegate send_web_push(message, subscription), to: GSMLG.WebPush.Encryption.Push

  defdelegate encrypt(message, subscription), to: GSMLG.WebPush.Encryption.Encrypt
  defdelegate encrypt(message, subscription, padding_length), to: GSMLG.WebPush.Encryption.Encrypt
end
