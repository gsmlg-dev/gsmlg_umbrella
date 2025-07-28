defmodule GSMLG.WebPush.Vapid do
  @moduledoc """
  Module for handling Vapid key generation and management
  """

  def generate_keys do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(public_key, padding: false),
      private_key: Base.url_encode64(private_key, padding: false)
    }
  end

  def get_public_key do
    Application.get_env(:gsmlg_web_push, :vapid_details)[:public_key]
  end

  def get_private_key do
    Application.get_env(:gsmlg_web_push, :vapid_details)[:private_key]
  end
end
