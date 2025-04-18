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
iex> ca_key = X509.PrivateKey.new_ec(:secp256r1)
{:ECPrivateKey, ...}
iex> ca = X509.Certificate.self_signed(ca_key,
...>   "/C=US/ST=CA/L=San Francisco/O=Acme/CN=ECDSA Root CA",
...>   template: :root_ca
...>)
{:OTPCertificate, ...}
```

Use the CA certificate to issue a server certificate, using the default
`server` template and the given SAN hostnames:

```elixir
iex> my_key = X509.PrivateKey.new_ec(:secp256r1)
{:ECPrivateKey, ...}
iex> my_cert = my_key |>
...> X509.PublicKey.derive() |>
...> X509.Certificate.new(
...>   "/C=US/ST=CA/L=San Francisco/O=Acme/CN=Sample",
...>   ca, ca_key,
...>   extensions: [
...>     subject_alt_name: X509.Certificate.Extension.subject_alt_name(["example.org", "www.example.org"])
...>   ]
...> )
{:OTPCertificate, ...}
```

Or sign a certificate based on an incoming CSR:

```elixir
iex> csr = X509.CSR.from_pem!(pem_string)
{:CertificationRequest, ...}
iex> subject = X509.CSR.subject(csr)
{:rdnSequence, ...}
iex> my_cert = csr |>
...> X509.CSR.public_key() |>
...> X509.Certificate.new(
...>   subject,
...>   ca, ca_key,
...>   extensions: [
...>     subject_alt_name: X509.Certificate.Extension.subject_alt_name(["example.org", "www.example.org"])
...>   ]
...> )
```

### With `:public_key` for encryption/signing

Please refer to the documentation for the `X509.PrivateKey` module for
examples showing asymmetrical encryption and decryption, as well as message
signing and verification, with Erlang/OTP's `:public_key` APIs.

### For TLS client/server testing

The `x509.gen.selfsigned` Mix task generates a self-signed certificate for use
with a TLS server in development or testing.

The `X509.Test.Suite` and `X509.Test.Server` modules may be used to create
test cases for TLS clients. The [server_test.exs](test/x509/test/server_test.exs)
file can serve as a template: update the `request/2` function to invoke of the
TLS client under test,  make sure it returns the expected response format, and
update the test server's canned response in the test module's setup if
necessary.

You may want to include the X509 package only in the 'dev' and/or 'test'
environments for this use-case, by adding an `only: ...` clause to the
dependency definition in your Mix file.

## Installation

Add `x509` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:x509, "~> 0.8"}
  ]
end
```

