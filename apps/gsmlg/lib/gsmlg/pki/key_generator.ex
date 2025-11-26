defmodule GSMLG.PKI.KeyGenerator do
  @moduledoc """
  Generates cryptographic key pairs for PKI operations.

  Supports RSA, ECDSA (P-256, P-384, P-521), and Ed25519 key generation
  with optional PKCS#8 password-based encryption.

  ## Supported Key Types

  - **RSA**: 2048, 3072, 4096, 8192 bits
  - **ECDSA**: P-256 (secp256r1), P-384 (secp384r1), P-521 (secp521r1)
  - **Ed25519**: 256-bit (fixed size)

  ## Examples

      # Generate RSA 4096-bit key
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 4096)

      # Generate ECDSA P-384 key
      {:ok, keypair} = KeyGenerator.generate_key(:ecdsa, 384)

      # Generate Ed25519 key (size ignored)
      {:ok, keypair} = KeyGenerator.generate_key(:ed25519, 256)

      # Generate encrypted RSA key
      {:ok, keypair} = KeyGenerator.generate_key(:rsa, 4096, password: "secret123")
  """

  @type key_type :: :rsa | :ecdsa | :ed25519
  @type key_size :: pos_integer()
  @type keypair :: %{
          private_key_pem: String.t(),
          public_key_pem: String.t(),
          algorithm_details: map(),
          encrypted: boolean()
        }

  @rsa_key_sizes [2048, 3072, 4096, 8192]
  @ecdsa_key_sizes [256, 384, 521]
  @ecdsa_curve_names %{
    256 => :secp256r1,
    384 => :secp384r1,
    521 => :secp521r1
  }

  @doc """
  Generates a cryptographic key pair.

  ## Parameters

  - `key_type` - Key algorithm (`:rsa`, `:ecdsa`, `:ed25519`)
  - `key_size` - Key size in bits (algorithm-specific valid values)
  - `opts` - Options keyword list:
    - `:password` - Password for PKCS#8 encryption (optional)
    - `:cipher` - Encryption cipher (default: `:aes_256_cbc`)

  ## Returns

  - `{:ok, keypair}` with fields:
    - `private_key_pem` - Private key in PEM format (possibly encrypted)
    - `public_key_pem` - Public key in PEM format
    - `algorithm_details` - Algorithm-specific metadata
    - `encrypted` - Whether private key is encrypted

  - `{:error, reason}` on failure
  """
  @spec generate_key(key_type(), key_size(), keyword()) :: {:ok, keypair()} | {:error, term()}
  def generate_key(key_type, key_size, opts \\ [])

  def generate_key(:rsa, key_size, opts) when key_size in @rsa_key_sizes do
    try do
      # Generate RSA key pair
      exponent = Keyword.get(opts, :exponent, 65537)
      private_key = :public_key.generate_key({:rsa, key_size, exponent})

      # Extract public key
      {:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _} = private_key
      public_key = {:RSAPublicKey, modulus, public_exponent}

      # Encode keys to PEM
      {private_pem, encrypted} = encode_private_key(private_key, :RSAPrivateKey, opts)
      public_pem = encode_public_key(public_key, :RSAPublicKey)

      {:ok,
       %{
         private_key_pem: private_pem,
         public_key_pem: public_pem,
         algorithm_details: %{
           "modulus_bits" => key_size,
           "public_exponent" => public_exponent
         },
         encrypted: encrypted
       }}
    rescue
      error -> {:error, {:key_generation_failed, error}}
    end
  end

  def generate_key(:ecdsa, key_size, opts) when key_size in @ecdsa_key_sizes do
    try do
      curve = Map.fetch!(@ecdsa_curve_names, key_size)

      # Generate ECDSA key pair
      private_key = :public_key.generate_key({:namedCurve, :pubkey_cert_records.namedCurves(curve)})

      # Extract public key
      {:ECPrivateKey, _, _, {_, public_key_point}, _} = private_key

      public_key =
        {:ECPoint, public_key_point}

      # Encode keys to PEM
      {private_pem, encrypted} = encode_private_key(private_key, :ECPrivateKey, opts)
      public_pem = encode_ec_public_key(public_key, curve)

      {:ok,
       %{
         private_key_pem: private_pem,
         public_key_pem: public_pem,
         algorithm_details: %{
           "curve_name" => Atom.to_string(curve),
           "key_size_bits" => key_size
         },
         encrypted: encrypted
       }}
    rescue
      error -> {:error, {:key_generation_failed, error}}
    end
  end

  def generate_key(:ed25519, _key_size, opts) do
    try do
      # Ed25519 has fixed 256-bit key size
      # Generate key pair using Erlang :crypto module
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      # Encode keys to PEM format
      {private_pem, encrypted} = encode_ed25519_private_key(private_key, opts)
      public_pem = encode_ed25519_public_key(public_key)

      {:ok,
       %{
         private_key_pem: private_pem,
         public_key_pem: public_pem,
         algorithm_details: %{
           "curve" => "ed25519",
           "key_size_bits" => 256
         },
         encrypted: encrypted
       }}
    rescue
      error -> {:error, {:key_generation_failed, error}}
    end
  end

  def generate_key(key_type, key_size, _opts) do
    {:error, {:invalid_key_parameters, key_type, key_size}}
  end

  @doc """
  Returns valid key sizes for a given key type.

  ## Examples

      iex> KeyGenerator.get_key_size_options(:rsa)
      [2048, 3072, 4096, 8192]

      iex> KeyGenerator.get_key_size_options(:ecdsa)
      [256, 384, 521]

      iex> KeyGenerator.get_key_size_options(:ed25519)
      []
  """
  @spec get_key_size_options(key_type()) :: [key_size()]
  def get_key_size_options(:rsa), do: @rsa_key_sizes
  def get_key_size_options(:ecdsa), do: @ecdsa_key_sizes
  def get_key_size_options(:ed25519), do: []

  # Private helper functions

  defp encode_private_key(private_key, key_type_atom, opts) do
    password = Keyword.get(opts, :password)

    if password do
      cipher = Keyword.get(opts, :cipher, :aes_256_cbc)
      cipher_info = cipher_info(cipher)

      encrypted_der =
        :public_key.pem_entry_encode(key_type_atom, private_key, {cipher_info, password})

      pem = :public_key.pem_encode([encrypted_der])
      {pem, true}
    else
      der = :public_key.pem_entry_encode(key_type_atom, private_key)
      pem = :public_key.pem_encode([der])
      {pem, false}
    end
  end

  defp encode_public_key(public_key, key_type_atom) do
    der = :public_key.pem_entry_encode(key_type_atom, public_key)
    :public_key.pem_encode([der])
  end

  defp encode_ec_public_key(public_key, curve) do
    # Encode EC public key with curve parameters
    curve_oid = :pubkey_cert_records.namedCurves(curve)

    subject_public_key_info = {
      :SubjectPublicKeyInfo,
      {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1},
       {:namedCurve, curve_oid}},
      public_key
    }

    der = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, subject_public_key_info)
    :public_key.pem_encode([der])
  end

  defp encode_ed25519_private_key(private_key, opts) do
    password = Keyword.get(opts, :password)

    # For Ed25519, we need to wrap the key in PKCS#8 format
    # This is a simplified version - production code may need more robust handling
    private_key_info = {
      :PrivateKeyInfo,
      :v1,
      {:PrivateKeyAlgorithm, {1, 3, 101, 112}, :asn1_NOVALUE},
      private_key,
      :asn1_NOVALUE
    }

    if password do
      cipher = Keyword.get(opts, :cipher, :aes_256_cbc)
      cipher_info = cipher_info(cipher)

      encrypted_der =
        :public_key.pem_entry_encode(:PrivateKeyInfo, private_key_info, {cipher_info, password})

      pem = :public_key.pem_encode([encrypted_der])
      {pem, true}
    else
      der = :public_key.pem_entry_encode(:PrivateKeyInfo, private_key_info)
      pem = :public_key.pem_encode([der])
      {pem, false}
    end
  end

  defp encode_ed25519_public_key(public_key) do
    subject_public_key_info = {
      :SubjectPublicKeyInfo,
      {:PublicKeyAlgorithm, {1, 3, 101, 112}, :asn1_NOVALUE},
      {:ECPoint, public_key}
    }

    der = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, subject_public_key_info)
    :public_key.pem_encode([der])
  end

  defp cipher_info(:aes_128_cbc), do: {"AES-128-CBC", :crypto.strong_rand_bytes(16)}
  defp cipher_info(:aes_256_cbc), do: {"AES-256-CBC", :crypto.strong_rand_bytes(32)}
  defp cipher_info(:des3_cbc), do: {"DES-EDE3-CBC", :crypto.strong_rand_bytes(24)}
end
