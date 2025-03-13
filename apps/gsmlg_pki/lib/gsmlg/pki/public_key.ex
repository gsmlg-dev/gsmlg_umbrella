defmodule GSMLG.PKI.PublicKey do
  import GSMLG.PKI.ASN1

  @typedoc "RSA or EC public key"
  @type t :: :public_key.rsa_public_key() | :public_key.ec_public_key()

  def derive(%{algorithm: algorithm, engine: _} = private_key) do
    :crypto.privkey_to_pubkey(algorithm, private_key)
  end

  def derive(rsa_private_key(modulus: m, publicExponent: e)) do
    rsa_public_key(modulus: m, publicExponent: e)
  end

  def derive(ec_private_key(parameters: params, publicKey: pub)) do
    {ec_point(point: pub), params}
  end

  def to_pem(public_key) do
    kind = public_key |> elem(0)
    :public_key.pem_entry_encode(kind, public_key)
    |> List.wrap()
    |> :public_key.pem_encode()
  end
end
