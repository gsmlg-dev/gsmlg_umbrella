defmodule GSMLG.PKI.ValidatorTest do
  use ExUnit.Case, async: false

  alias GSMLG.PKI.{CA, Validator, PrivateKey, PublicKey, Events}

  import GSMLG.PKI.ASN1

  setup_all do
    # Setup CouchDB database for testing
    Application.put_env(:gsmlg_pki, GSMLG.PKI.Store.CouchDB, database: "pki_events_test")

    case GSMLG.PKI.Store.CouchDB.setup() do
      :ok -> :ok
      {:error, _} -> :ok
    end

    :ok
  end

  setup do
    # Create root CA
    test_id = :erlang.unique_integer([:positive])

    {:ok, root_ca} =
      CA.initialize("/CN=Root CA #{test_id}",
        key_type: :rsa,
        key_size: 2048,
        validity: 7300
      )

    {:ok, root_ca: root_ca, test_id: test_id}
  end

  describe "Validator.validate_chain/3" do
    test "validates a valid certificate chain", %{root_ca: root_ca} do
      # Issue certificate
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          root_ca,
          public_key,
          "/CN=example.com",
          template: :server,
          validity: 365
        )

      # Validate
      {:ok, :valid} = Validator.validate_chain(cert, [root_ca.certificate])
    end

    test "validates with revocation checking disabled", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(root_ca, public_key, "/CN=test.com")

      # Revoke certificate
      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs
      :ok = CA.revoke_certificate(root_ca, serial, reason: :keyCompromise)

      # Should still be valid if revocation checking is disabled
      {:ok, :valid} = Validator.validate_chain(cert, [root_ca.certificate], check_revocation: false)
    end

    test "detects revoked certificate", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=revoked.com")

      # Revoke
      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs
      :ok = CA.revoke_certificate(root_ca, serial, reason: :keyCompromise)

      # Validate with revocation checking
      {:ok, {:invalid, {:revoked, :keyCompromise}}} =
        Validator.validate_chain(cert, [root_ca.certificate], check_revocation: true)
    end

    test "detects expired certificate", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      # Issue certificate valid for 1 day
      {:ok, cert} =
        CA.issue_certificate_direct(root_ca, public_key, "/CN=expired.com",
          validity: 1
        )

      # Check at future time (2 days from now)
      future_time = DateTime.add(DateTime.utc_now(), 2, :day)

      {:ok, {:invalid, :expired}} =
        Validator.validate_chain(cert, [root_ca.certificate], at_time: future_time)
    end

    test "detects not-yet-valid certificate", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(root_ca, public_key, "/CN=future.com")

      # Check at past time (before certificate was issued)
      past_time = DateTime.add(DateTime.utc_now(), -365, :day)

      {:ok, {:invalid, :not_yet_valid}} =
        Validator.validate_chain(cert, [root_ca.certificate], at_time: past_time)
    end

    test "validates self-signed root CA", %{root_ca: root_ca} do
      # Root CA should validate itself
      {:ok, :valid} = Validator.validate_chain(root_ca.certificate, [root_ca.certificate])
    end

    test "returns error for incomplete chain" do
      # Create a certificate signed by unknown CA
      ca_key = PrivateKey.new_rsa(2048)

      unknown_ca =
        GSMLG.PKI.Certificate.self_signed(ca_key, "/CN=Unknown CA",
          template: :root_ca,
          validity: 365
        )

      # Issue cert from unknown CA
      cert_key = PrivateKey.new_rsa(2048)
      cert_public_key = PublicKey.derive(cert_key)

      cert =
        GSMLG.PKI.Certificate.new(
          cert_public_key,
          "/CN=orphan.com",
          unknown_ca,
          ca_key,
          template: :server
        )

      # Create a different root CA for trust anchor
      different_ca_key = PrivateKey.new_rsa(2048)

      different_root =
        GSMLG.PKI.Certificate.self_signed(different_ca_key, "/CN=Different Root",
          template: :root_ca
        )

      # Should fail - cert not signed by trusted root
      {:error, :incomplete_chain} = Validator.validate_chain(cert, [different_root])
    end
  end

  describe "Validator.check_revocation/2" do
    test "returns not_revoked for active certificate", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=active.com")

      {:ok, :not_revoked} = Validator.check_revocation(cert)
    end

    test "returns revoked for revoked certificate", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=revoked.com")

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs
      :ok = CA.revoke_certificate(root_ca, serial, reason: :keyCompromise)

      {:ok, {:revoked, :keyCompromise}} = Validator.check_revocation(cert)
    end

    test "checks revocation at specific time", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=time-test.com")

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # Certificate is active now
      before_revocation = DateTime.utc_now()
      {:ok, :not_revoked} = Validator.check_revocation(cert, before_revocation)

      # Wait a moment then revoke
      Process.sleep(100)
      :ok = CA.revoke_certificate(root_ca, serial, reason: :keyCompromise)

      # Should be not revoked at the earlier time
      {:ok, :not_revoked} = Validator.check_revocation(cert, before_revocation)

      # Should be revoked now
      {:ok, {:revoked, :keyCompromise}} = Validator.check_revocation(cert, DateTime.utc_now())
    end

    test "returns not_revoked for unknown certificate" do
      # Create a certificate that was never logged to events
      key = PrivateKey.new_rsa(2048)

      cert =
        GSMLG.PKI.Certificate.self_signed(key, "/CN=Unknown Cert",
          template: :server
        )

      # Should return not_revoked (unknown certificates are not revoked)
      {:ok, :not_revoked} = Validator.check_revocation(cert)
    end
  end

  describe "Validator.validate_key_usage/2" do
    test "validates correct key usage", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(root_ca, public_key, "/CN=server.com",
          template: :server
        )

      # Server template should have serverAuth
      :ok = Validator.validate_key_usage(cert, :serverAuth)
    end

    test "validates when no usage is required" do
      key = PrivateKey.new_rsa(2048)
      cert = GSMLG.PKI.Certificate.self_signed(key, "/CN=Test")

      # nil usage should always pass
      :ok = Validator.validate_key_usage(cert, nil)
    end
  end

  describe "Validator.build_chain/4" do
    test "builds simple chain: leaf -> root", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=leaf.com")

      {:ok, chain} = Validator.build_chain(cert, [root_ca.certificate], [])

      assert length(chain) == 2
      assert List.first(chain) == cert
      assert List.last(chain) == root_ca.certificate
    end

    test "builds three-level chain: leaf -> intermediate -> root", %{root_ca: root_ca} do
      # Create intermediate CA
      int_key = PrivateKey.new_rsa(2048)
      int_public_key = PublicKey.derive(int_key)

      {:ok, int_cert} =
        CA.issue_certificate_direct(
          root_ca,
          int_public_key,
          "/CN=Intermediate CA",
          template: :intermediate_ca,
          validity: 3650
        )

      # Issue leaf from intermediate (simulated)
      leaf_key = PrivateKey.new_rsa(2048)
      leaf_public_key = PublicKey.derive(leaf_key)

      leaf_cert =
        GSMLG.PKI.Certificate.new(
          leaf_public_key,
          "/CN=leaf.example.com",
          int_cert,
          int_key,
          template: :server
        )

      # Build chain
      {:ok, chain} = Validator.build_chain(leaf_cert, [root_ca.certificate], [int_cert])

      assert length(chain) == 3
      assert Enum.at(chain, 0) == leaf_cert
      assert Enum.at(chain, 1) == int_cert
      assert Enum.at(chain, 2) == root_ca.certificate
    end

    test "returns error for chain too long" do
      # Create a very long chain (exceeding max_length)
      key = PrivateKey.new_rsa(2048)
      cert = GSMLG.PKI.Certificate.self_signed(key, "/CN=Test")

      # Try to build chain with max_length = 0
      {:error, :chain_too_long} = Validator.build_chain(cert, [], [], 0)
    end
  end

  describe "Integration: Complex validation scenarios" do
    test "validates certificate chain with intermediate CA", %{root_ca: root_ca} do
      # Create intermediate CA
      int_key = PrivateKey.new_rsa(2048)
      int_public_key = PublicKey.derive(int_key)

      {:ok, int_cert} =
        CA.issue_certificate_direct(
          root_ca,
          int_public_key,
          "/CN=Intermediate CA",
          template: :intermediate_ca,
          validity: 3650
        )

      # Issue leaf certificate from intermediate
      leaf_key = PrivateKey.new_rsa(2048)
      leaf_public_key = PublicKey.derive(leaf_key)

      leaf_cert =
        GSMLG.PKI.Certificate.new(
          leaf_public_key,
          "/CN=www.example.com",
          int_cert,
          int_key,
          template: :server
        )

      # Validate chain
      {:ok, :valid} =
        Validator.validate_chain(
          leaf_cert,
          [root_ca.certificate],
          intermediates: [int_cert],
          check_revocation: false
        )
    end

    test "validation logs event", %{root_ca: root_ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(root_ca, public_key, "/CN=logged.com")

      # Validate
      {:ok, :valid} = Validator.validate_chain(cert, [root_ca.certificate])

      # Check validation events were logged
      {:ok, events} = Events.query_by_type(:certificate_validated)
      assert length(events) >= 1
    end
  end
end
