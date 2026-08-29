defmodule GSMLG.AdminWeb.ClientCertificateTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.ClientCertificate
  alias GSMLG.AdminWeb.ClientCertificateFixtures

  import ClientCertificateFixtures

  test "parses a valid client certificate" do
    certificate = client_certificate()

    assert {:ok, parsed} =
             ClientCertificate.parse_headers(client_certificate_headers(certificate))

    assert parsed.certificate_der == certificate.certificate_der
    assert parsed.fingerprint == certificate.fingerprint
    assert parsed.pem == certificate.pem
    assert parsed.subject == certificate.subject
    assert parsed.email == certificate.email
  end

  test "rejects headers when all certificate headers are absent" do
    assert {:error, :missing_headers} = ClientCertificate.parse_headers([])
  end

  test "rejects incomplete certificate headers" do
    certificate = client_certificate()

    [first | _] = client_certificate_headers(certificate)
    assert {:error, :incomplete_headers} = ClientCertificate.parse_headers([first])
  end

  test "rejects blank certificate headers" do
    certificate = client_certificate()

    headers = client_certificate_headers(certificate)

    assert {:error, :blank_header} =
             ClientCertificate.parse_headers(put_header(headers, "x-client-cert-email", "  "))
  end

  test "rejects an empty certificate" do
    certificate = client_certificate()

    headers =
      put_header(client_certificate_headers(certificate), "x-client-cert-certificate-pem", "")

    assert {:error, :empty_certificate} = ClientCertificate.parse_headers(headers)
  end

  test "rejects duplicate certificate headers" do
    certificate = client_certificate()
    headers = client_certificate_headers(certificate)
    {name, value} = hd(headers)

    assert {:error, :duplicate_header} =
             ClientCertificate.parse_headers([{name, value} | headers])
  end

  test "rejects malformed base64" do
    certificate = client_certificate()

    headers =
      put_header(
        client_certificate_headers(certificate),
        "x-client-cert-certificate-pem",
        "not-base64"
      )

    assert {:error, :invalid_base64} = ClientCertificate.parse_headers(headers)
  end

  test "rejects non-canonical certificate base64" do
    certificate = client_certificate()
    der = certificate.certificate_der
    mutated = mutate_final_base64_character(certificate.der_base64)

    assert {:ok, ^der} = Base.decode64(mutated)

    headers =
      put_header(
        client_certificate_headers(certificate),
        "x-client-cert-certificate-pem",
        mutated
      )

    assert {:error, :invalid_base64} = ClientCertificate.parse_headers(headers)
  end

  test "rejects invalid certificate header values without raising" do
    certificate = client_certificate()
    headers = put_header(client_certificate_headers(certificate), "x-client-cert-subject", 123)

    assert {:error, :invalid_header} = ClientCertificate.parse_headers(headers)
  end

  test "rejects certificates larger than 16 KiB" do
    certificate = client_certificate()
    oversized = Base.encode64(:binary.copy(<<0>>, 16_385))

    headers =
      put_header(
        client_certificate_headers(certificate),
        "x-client-cert-certificate-pem",
        oversized
      )

    assert {:error, :certificate_too_large} = ClientCertificate.parse_headers(headers)
  end

  test "rejects non-X.509 DER" do
    certificate = client_certificate()

    headers =
      put_header(
        client_certificate_headers(certificate),
        "x-client-cert-certificate-pem",
        Base.encode64(<<1, 2, 3>>)
      )

    assert {:error, :invalid_certificate} = ClientCertificate.parse_headers(headers)
  end

  test "rejects valid certificates with trailing DER data" do
    certificate = client_certificate()
    encoded = Base.encode64(certificate.certificate_der <> <<0, 1, 2>>)

    headers =
      put_header(
        client_certificate_headers(certificate),
        "x-client-cert-certificate-pem",
        encoded
      )

    assert {:error, :invalid_certificate} = ClientCertificate.parse_headers(headers)
  end

  test "matches header names case-insensitively and preserves subject and email" do
    certificate =
      client_certificate(%{subject: "  CN=Exact Subject  ", email: " exact@example.com "})

    headers =
      client_certificate_headers(certificate)
      |> Enum.map(fn {name, value} -> {String.upcase(name), value} end)

    assert {:ok, parsed} = ClientCertificate.parse_headers(headers)
    assert parsed.subject == certificate.subject
    assert parsed.email == certificate.email
  end

  test "parses certificate headers from a Plug connection" do
    certificate = client_certificate()

    conn =
      Plug.Test.conn(:get, "/")
      |> put_client_certificate_headers(certificate)

    assert {:ok, parsed} = ClientCertificate.parse_conn(conn)
    assert parsed.fingerprint == certificate.fingerprint
  end

  defp put_header(headers, target, value) do
    Enum.map(headers, fn
      {^target, _old_value} -> {target, value}
      pair -> pair
    end)
  end

  defp mutate_final_base64_character(encoded) do
    padding_length =
      encoded
      |> String.reverse()
      |> String.graphemes()
      |> Enum.take_while(&(&1 == "="))
      |> length()

    data_length = byte_size(encoded) - padding_length
    prefix = binary_part(encoded, 0, data_length - 1)
    final = binary_part(encoded, data_length - 1, 1)
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    index = Enum.find_index(alphabet, &(<<&1>> == final))
    replacement = Enum.at(alphabet, index + 1)

    prefix <> <<replacement>> <> binary_part(encoded, data_length, padding_length)
  end
end
