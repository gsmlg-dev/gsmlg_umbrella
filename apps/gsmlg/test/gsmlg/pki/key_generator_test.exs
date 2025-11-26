defmodule GSMLG.PKI.KeyGeneratorTest do
  use ExUnit.Case, async: true

  alias GSMLG.PKI.KeyGenerator

  describe "generate_key/3 with RSA" do
    test "generates RSA 2048-bit key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:rsa, 2048)

      assert keypair.private_key_pem =~ "-----BEGIN RSA PRIVATE KEY-----"
      assert keypair.public_key_pem =~ "-----BEGIN RSA PUBLIC KEY-----"
      assert keypair.algorithm_details["modulus_bits"] == 2048
      assert keypair.algorithm_details["public_exponent"] == 65537
      assert keypair.encrypted == false
    end

    test "generates RSA 4096-bit key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:rsa, 4096)

      assert keypair.algorithm_details["modulus_bits"] == 4096
      assert keypair.encrypted == false
    end

    test "generates RSA 8192-bit key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:rsa, 8192)

      assert keypair.algorithm_details["modulus_bits"] == 8192
    end

    test "returns error for invalid RSA key size" do
      assert {:error, {:invalid_key_parameters, :rsa, 1024}} =
               KeyGenerator.generate_key(:rsa, 1024)
    end

    test "generates encrypted RSA key with password" do
      assert {:ok, keypair} =
               KeyGenerator.generate_key(:rsa, 2048, password: "test_password_123")

      assert keypair.private_key_pem =~ "-----BEGIN ENCRYPTED PRIVATE KEY-----" or
               keypair.private_key_pem =~ "ENCRYPTED"

      assert keypair.encrypted == true
    end
  end

  describe "generate_key/3 with ECDSA" do
    test "generates ECDSA P-256 key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:ecdsa, 256)

      assert keypair.private_key_pem =~ "-----BEGIN EC PRIVATE KEY-----"
      assert keypair.public_key_pem =~ "-----BEGIN PUBLIC KEY-----"
      assert keypair.algorithm_details["curve_name"] == "secp256r1"
      assert keypair.algorithm_details["key_size_bits"] == 256
      assert keypair.encrypted == false
    end

    test "generates ECDSA P-384 key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:ecdsa, 384)

      assert keypair.algorithm_details["curve_name"] == "secp384r1"
      assert keypair.algorithm_details["key_size_bits"] == 384
    end

    test "generates ECDSA P-521 key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:ecdsa, 521)

      assert keypair.algorithm_details["curve_name"] == "secp521r1"
      assert keypair.algorithm_details["key_size_bits"] == 521
    end

    test "returns error for invalid ECDSA key size" do
      assert {:error, {:invalid_key_parameters, :ecdsa, 128}} =
               KeyGenerator.generate_key(:ecdsa, 128)
    end

    test "generates encrypted ECDSA key with password" do
      assert {:ok, keypair} =
               KeyGenerator.generate_key(:ecdsa, 384, password: "secure_pass_456")

      assert keypair.encrypted == true
    end
  end

  describe "generate_key/3 with Ed25519" do
    test "generates Ed25519 key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:ed25519, 256)

      assert keypair.private_key_pem =~ "-----BEGIN PRIVATE KEY-----"
      assert keypair.public_key_pem =~ "-----BEGIN PUBLIC KEY-----"
      assert keypair.algorithm_details["curve"] == "ed25519"
      assert keypair.algorithm_details["key_size_bits"] == 256
      assert keypair.encrypted == false
    end

    test "generates encrypted Ed25519 key with password" do
      assert {:ok, keypair} =
               KeyGenerator.generate_key(:ed25519, 256, password: "ed25519_password")

      assert keypair.encrypted == true
    end

    test "ignores key_size parameter (Ed25519 is fixed 256-bit)" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:ed25519, 9999)

      assert keypair.algorithm_details["key_size_bits"] == 256
    end
  end

  describe "get_key_size_options/1" do
    test "returns RSA key size options" do
      assert KeyGenerator.get_key_size_options(:rsa) == [2048, 3072, 4096, 8192]
    end

    test "returns ECDSA key size options" do
      assert KeyGenerator.get_key_size_options(:ecdsa) == [256, 384, 521]
    end

    test "returns empty list for Ed25519 (fixed size)" do
      assert KeyGenerator.get_key_size_options(:ed25519) == []
    end
  end

  describe "key encryption with different ciphers" do
    test "generates RSA key with AES-256-CBC encryption" do
      assert {:ok, keypair} =
               KeyGenerator.generate_key(:rsa, 2048,
                 password: "test123",
                 cipher: :aes_256_cbc
               )

      assert keypair.encrypted == true
    end

    test "generates RSA key with AES-128-CBC encryption" do
      assert {:ok, keypair} =
               KeyGenerator.generate_key(:rsa, 2048,
                 password: "test123",
                 cipher: :aes_128_cbc
               )

      assert keypair.encrypted == true
    end
  end

  describe "PEM format validation" do
    test "generated RSA private key is valid PEM" do
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 2048)

      assert [entry] = :public_key.pem_decode(keypair.private_key_pem)
      assert {:RSAPrivateKey, _, _} = entry
    end

    test "generated ECDSA private key is valid PEM" do
      {:ok, keypair} = KeyGenerator.generate_key(:ecdsa, 256)

      assert [_entry] = :public_key.pem_decode(keypair.private_key_pem)
      # ECDSA keys are wrapped in ECPrivateKey format
    end

    test "generated public keys are valid PEM" do
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 2048)

      assert [_entry] = :public_key.pem_decode(keypair.public_key_pem)
    end
  end
end
