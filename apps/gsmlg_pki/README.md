# GSMLG.PKI

## Installation

[Hex](https://hex.pm/packages/gsmlg_pki)

Package can be installed by adding `gsmlg_pki` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_pki, "~> 0.1.0"}
  ]
end
```


## Usage

### As a Certificate Authority (CA)

Generate a self-signed CA certificate and private key, using the `root_ca`
template:

```elixir
iex> ca_key = GSMLG.PKI.PrivateKey.new_ec(:secp256r1)
{:ECPrivateKey, ...}
iex> ca = GSMLG.PKI.Certificate.self_signed(ca_key,
...>   "/C=US/ST=CA/L=San Francisco/O=Acme/CN=ECDSA Root CA",
...>   template: :root_ca
...>)
{:OTPCertificate, ...}
```

Use the CA certificate to issue a server certificate, using the default
`server` template and the given SAN hostnames:

```elixir
iex> my_key = GSMLG.PKI.PrivateKey.new_ec(:secp256r1)
{:ECPrivateKey, ...}
iex> my_cert = my_key |>
...> GSMLG.PKI.PublicKey.derive() |>
...> GSMLG.PKI.Certificate.new(
...>   "/C=US/ST=CA/L=San Francisco/O=Acme/CN=Sample",
...>   ca, ca_key,
...>   extensions: [
...>     subject_alt_name: GSMLG.PKI.Certificate.Extension.subject_alt_name(["example.org", "www.example.org"])
...>   ]
...> )
{:OTPCertificate, ...}
```

Or sign a certificate based on an incoming CSR:

```elixir
iex> csr = GSMLG.PKI.CSR.from_pem!(pem_string)
{:CertificationRequest, ...}
iex> subject = GSMLG.PKI.CSR.subject(csr)
{:rdnSequence, ...}
iex> my_cert = csr |>
...> GSMLG.PKI.CSR.public_key() |>
...> GSMLG.PKI.Certificate.new(
...>   subject,
...>   ca, ca_key,
...>   extensions: [
...>     subject_alt_name: GSMLG.PKI.Certificate.Extension.subject_alt_name(["example.org", "www.example.org"])
...>   ]
...> )
```

### With `:public_key` for encryption/signing

Please refer to the documentation for the `GSMLG.PKI.PrivateKey` module for
examples showing asymmetrical encryption and decryption, as well as message
signing and verification, with Erlang/OTP's `:public_key` APIs.

### For TLS client/server testing

The `gSMLG.PKI.gen.selfsigned` Mix task generates a self-signed certificate for use
with a TLS server in development or testing.

The `GSMLG.PKI.Test.Suite` and `GSMLG.PKI.Test.Server` modules may be used to create
test cases for TLS clients. The [server_test.exs](test/gsmlg/pki/server_test.exs)
file can serve as a template: update the `request/2` function to invoke of the
TLS client under test,  make sure it returns the expected response format, and
update the test server's canned response in the test module's setup if
necessary.
