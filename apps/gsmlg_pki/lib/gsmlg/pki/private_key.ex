defmodule GSMLG.PKI.PrivateKey do
  import GSMLG.PKI.ASN1

  @typedoc "RSA or EC private key"
  @type t :: :public_key.rsa_private_key() | :public_key.ec_private_key()

  # @private_key_records [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
  @default_exponent 65537

  def new_rsa(key_size \\ 2048) do
    :public_key.generate_key({:rsa, key_size, @default_exponent})
  end

  def pubkey(private_key) do
    rsa_private_key(modulus: m, publicExponent: e) = private_key
    rsa_public_key(modulus: m, publicExponent: e)
  end

  def to_pem(private_key, password \\ nil) do
    kind = private_key |> elem(0)
    if is_nil(password) do
      :public_key.pem_entry_encode(kind, private_key)
    else
      :public_key.pem_entry_encode(
        kind,
        private_key,
        {{~c"DES-EDE3-CBC", :crypto.strong_rand_bytes(8)}, ~c"#{password}"}
      )
    end
    |> List.wrap()
    |> :public_key.pem_encode()
  end
end
