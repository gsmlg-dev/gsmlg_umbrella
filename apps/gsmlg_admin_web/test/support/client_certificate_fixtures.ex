defmodule GSMLG.AdminWeb.ClientCertificateFixtures do
  def client_certificate(overrides \\ %{}) do
    certificate_der =
      :public_key.pkix_test_data(%{root: [], peer: []})
      |> Keyword.fetch!(:cert)

    values =
      %{
        certificate_der: certificate_der,
        fingerprint: :crypto.hash(:sha256, certificate_der) |> Base.encode16(case: :lower),
        pem: :public_key.pem_encode([{:Certificate, certificate_der, :not_encrypted}]),
        subject: "CN=client.example.com",
        email: "client@example.com"
      }
      |> Map.merge(overrides)

    values
    |> Map.put(:der_base64, Base.encode64(values.certificate_der))
  end

  def client_certificate_headers(certificate) do
    [
      {"x-client-cert-subject", certificate.subject},
      {"x-client-cert-certificate-pem", certificate.der_base64},
      {"x-client-cert-email", certificate.email}
    ]
  end

  def put_client_certificate_headers(conn, certificate) do
    Enum.reduce(client_certificate_headers(certificate), conn, fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end
end
