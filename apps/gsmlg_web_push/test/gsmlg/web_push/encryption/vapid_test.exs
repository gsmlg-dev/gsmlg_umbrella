defmodule GSMLG.WebPush.Encryption.VapidTest do
  use ExUnit.Case

  alias GSMLG.WebPush.Encryption.Vapid

  describe "get_headers/2" do
    test "returns headers with Authorization and Crypto-Key for aesgcm" do
      headers = Vapid.get_headers("http://localhost/", "aesgcm")

      # Verify Authorization header format
      assert %{"Authorization" => auth} = headers
      assert String.starts_with?(auth, "WebPush ")

      # Verify Crypto-Key header format
      assert %{"Crypto-Key" => crypto_key} = headers
      assert String.starts_with?(crypto_key, "p256ecdsa=")

      # Extract and validate JWT structure (3 parts separated by dots)
      "WebPush " <> jwt = auth
      jwt_parts = String.split(jwt, ".")
      assert length(jwt_parts) == 3

      # Extract and validate public key is valid base64url
      "p256ecdsa=" <> public_key = crypto_key
      assert {:ok, _} = Base.url_decode64(public_key, padding: false)
    end

    # Note: aes128gcm is not currently in @supported_encodings
    # The module only supports "aesgcm" encoding for now
  end
end
