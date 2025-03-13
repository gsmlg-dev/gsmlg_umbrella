defmodule GSMLG.PKI.PublicKeyTest do
  use ExUnit.Case

  alias GSMLG.PKI.PublicKey

  describe "Public Key Test" do

    test "derive rsa public key" do
      private_key = :public_key.generate_key({:rsa, 2048, 65537})
      pubkey = PublicKey.derive(private_key)
      assert :RSAPublicKey = pubkey |> elem(0)
    end

    test "rsa key to_pem" do
      private_key = :public_key.generate_key({:rsa, 2048, 65537})
      pubkey = PublicKey.derive(private_key)
      assert pubkey |> PublicKey.to_pem() =~ "-----BEGIN RSA PUBLIC KEY-----"
    end
  end
end
