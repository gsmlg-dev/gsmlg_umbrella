defmodule GSMLG.PKI.CertificateTest do
  use ExUnit.Case

  alias GSMLG.PKI.Certificate

  describe "Public Key Test" do
    test "test create self signed certificate" do
      private_key = :public_key.generate_key({:rsa, 2048, 65537})

      cert =
        Certificate.self_signed(
          private_key,
          "/C=CN/ST=BJ/L=Chang Ping/O=GSMLG/CN=GSMLG Root CA",
          template: :root_ca
        )

      assert cert |> elem(0) == :OTPCertificate
      # IO.inspect(cert, limit: :infinity)
    end
  end
end
