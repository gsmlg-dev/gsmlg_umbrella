defmodule GSMLG.PKI.PrivateKeyTest do
  use ExUnit.Case

  alias GSMLG.PKI.PrivateKey

  describe "Private Key Test" do
    test "create rsa key" do
      rsa_key = PrivateKey.new_rsa(2048)
      assert :RSAPrivateKey = rsa_key |> elem(0)
    end

    test "rsa key to_pem" do
      rsa_key = PrivateKey.new_rsa(4096)
      assert rsa_key |> PrivateKey.to_pem() =~ "-----BEGIN RSA PRIVATE KEY-----"
    end
  end
end
