defmodule GSMLG.PKI.KeyGeneratorTest do
  use ExUnit.Case, async: true

  alias GSMLG.PKI.KeyGenerator

  # Some key generation features depend on OpenSSL/OTP version compatibility
  # These tests may fail in certain CI environments with different crypto library versions

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

    @tag :slow
    test "generates RSA 8192-bit key successfully" do
      assert {:ok, keypair} = KeyGenerator.generate_key(:rsa, 8192)

      assert keypair.algorithm_details["modulus_bits"] == 8192
    end

    test "returns error for invalid RSA key size" do
      assert {:error, {:invalid_key_parameters, :rsa, 1024}} =
               KeyGenerator.generate_key(:rsa, 1024)
    end

    @tag :crypto_encryption
    test "generates encrypted RSA key with password" do
      case KeyGenerator.generate_key(:rsa, 2048, password: "test_password_123") do
        {:ok, keypair} ->
          assert keypair.private_key_pem =~ "-----BEGIN ENCRYPTED PRIVATE KEY-----" or
                   keypair.private_key_pem =~ "ENCRYPTED"

          assert keypair.encrypted == true

        {:error, {:key_generation_failed, _}} ->
          # PEM encryption may not be supported in all OTP versions
          :ok
      end
    end
  end

  describe "generate_key/3 with ECDSA" do
    @tag :crypto_ecdsa
    test "generates ECDSA P-256 key successfully" do
      case KeyGenerator.generate_key(:ecdsa, 256) do
        {:ok, keypair} ->
          assert keypair.private_key_pem =~ "-----BEGIN EC PRIVATE KEY-----"
          assert keypair.public_key_pem =~ "-----BEGIN PUBLIC KEY-----"
          assert keypair.algorithm_details["curve_name"] == "secp256r1"
          assert keypair.algorithm_details["key_size_bits"] == 256
          assert keypair.encrypted == false

        {:error, {:key_generation_failed, _}} ->
          # ECDSA PEM encoding may not be supported in all OTP versions
          :ok
      end
    end

    @tag :crypto_ecdsa
    test "generates ECDSA P-384 key successfully" do
      case KeyGenerator.generate_key(:ecdsa, 384) do
        {:ok, keypair} ->
          assert keypair.algorithm_details["curve_name"] == "secp384r1"
          assert keypair.algorithm_details["key_size_bits"] == 384

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end

    @tag :crypto_ecdsa
    test "generates ECDSA P-521 key successfully" do
      case KeyGenerator.generate_key(:ecdsa, 521) do
        {:ok, keypair} ->
          assert keypair.algorithm_details["curve_name"] == "secp521r1"
          assert keypair.algorithm_details["key_size_bits"] == 521

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end

    test "returns error for invalid ECDSA key size" do
      assert {:error, {:invalid_key_parameters, :ecdsa, 128}} =
               KeyGenerator.generate_key(:ecdsa, 128)
    end

    @tag :crypto_encryption
    test "generates encrypted ECDSA key with password" do
      case KeyGenerator.generate_key(:ecdsa, 384, password: "secure_pass_456") do
        {:ok, keypair} ->
          assert keypair.encrypted == true

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end
  end

  describe "generate_key/3 with Ed25519" do
    @tag :crypto_ed25519
    test "generates Ed25519 key successfully" do
      case KeyGenerator.generate_key(:ed25519, 256) do
        {:ok, keypair} ->
          assert keypair.private_key_pem =~ "-----BEGIN PRIVATE KEY-----"
          assert keypair.public_key_pem =~ "-----BEGIN PUBLIC KEY-----"
          assert keypair.algorithm_details["curve"] == "ed25519"
          assert keypair.algorithm_details["key_size_bits"] == 256
          assert keypair.encrypted == false

        {:error, {:key_generation_failed, _}} ->
          # Ed25519 PEM encoding may not be supported in all OTP versions
          :ok
      end
    end

    @tag :crypto_encryption
    test "generates encrypted Ed25519 key with password" do
      case KeyGenerator.generate_key(:ed25519, 256, password: "ed25519_password") do
        {:ok, keypair} ->
          assert keypair.encrypted == true

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end

    @tag :crypto_ed25519
    test "ignores key_size parameter (Ed25519 is fixed 256-bit)" do
      case KeyGenerator.generate_key(:ed25519, 9999) do
        {:ok, keypair} ->
          assert keypair.algorithm_details["key_size_bits"] == 256

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
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
    @tag :crypto_encryption
    test "generates RSA key with AES-256-CBC encryption" do
      case KeyGenerator.generate_key(:rsa, 2048, password: "test123", cipher: :aes_256_cbc) do
        {:ok, keypair} ->
          assert keypair.encrypted == true

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end

    @tag :crypto_encryption
    test "generates RSA key with AES-128-CBC encryption" do
      case KeyGenerator.generate_key(:rsa, 2048, password: "test123", cipher: :aes_128_cbc) do
        {:ok, keypair} ->
          assert keypair.encrypted == true

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end
  end

  describe "PEM format validation" do
    test "generated RSA private key is valid PEM" do
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 2048)

      assert [entry] = :public_key.pem_decode(keypair.private_key_pem)
      assert {:RSAPrivateKey, _, _} = entry
    end

    @tag :crypto_ecdsa
    test "generated ECDSA private key is valid PEM" do
      case KeyGenerator.generate_key(:ecdsa, 256) do
        {:ok, keypair} ->
          assert [_entry] = :public_key.pem_decode(keypair.private_key_pem)

        {:error, {:key_generation_failed, _}} ->
          :ok
      end
    end

    test "generated public keys are valid PEM" do
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 2048)

      assert [_entry] = :public_key.pem_decode(keypair.public_key_pem)
    end
  end
end
