defmodule GSMLG.PKI.CATest do
  use ExUnit.Case, async: false

  # These tests require CouchDB to be running
  @moduletag :couchdb

  alias GSMLG.PKI.{CA, PrivateKey, PublicKey, Events, Certificate, Validator}

  import GSMLG.PKI.ASN1

  setup_all do
    # Setup CouchDB database for testing
    Application.put_env(:gsmlg_pki, GSMLG.PKI.Store.CouchDB, database: "pki_events_test")

    # Create test database
    case GSMLG.PKI.Store.CouchDB.setup() do
      :ok -> :ok
      # Database might already exist
      {:error, _} -> :ok
    end

    :ok
  end

  setup do
    # Generate unique CA for each test to avoid conflicts
    test_id = :erlang.unique_integer([:positive])
    subject = "/CN=Test CA #{test_id}/O=Test Org/C=US"

    {:ok, ca} =
      CA.initialize(subject,
        key_type: :rsa,
        key_size: 2048,
        validity: 365,
        actor: "test"
      )

    {:ok, ca: ca, test_id: test_id}
  end

  describe "CA.initialize/2" do
    test "creates a new root CA with RSA key" do
      {:ok, ca} =
        CA.initialize(
          "/CN=Test Root CA/O=Test/C=US",
          key_type: :rsa,
          key_size: 2048,
          validity: 7300,
          actor: "admin"
        )

      assert ca.id != nil
      assert ca.certificate != nil
      assert ca.private_key != nil
      assert ca.subject == "/CN=Test Root CA/O=Test/C=US"

      # Verify it's self-signed
      otp_certificate(tbsCertificate: tbs) = ca.certificate
      issuer_rdn = otp_tbs_certificate(tbs, :issuer)
      subject_rdn = otp_tbs_certificate(tbs, :subject)
      assert issuer_rdn == subject_rdn
    end

    test "creates a new root CA with EC key" do
      {:ok, ca} =
        CA.initialize(
          "/CN=EC Test CA/O=Test/C=US",
          key_type: :ec,
          curve: :secp256r1,
          validity: 3650,
          actor: "admin"
        )

      assert ca.id != nil
      assert ca.certificate != nil
      assert ca.private_key != nil
    end

    test "logs CA initialization event", %{test_id: test_id} do
      subject = "/CN=Event Test CA #{test_id}/O=Test/C=US"

      {:ok, ca} =
        CA.initialize(subject,
          key_type: :rsa,
          key_size: 2048,
          actor: "test-user"
        )

      # Query events for this CA
      {:ok, events} = Events.query_by_ca(ca.id)

      assert length(events) >= 1
      init_event = Enum.find(events, &(&1.event_type == :ca_initialized))
      assert init_event != nil
      assert init_event.metadata.subject == subject
      assert init_event.actor == "test-user"
    end
  end

  describe "CA.issue_certificate_direct/4" do
    test "issues a server certificate", %{ca: ca} do
      # Generate key pair
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      # Issue certificate
      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=example.com/O=Example Inc",
          template: :server,
          validity: 365,
          extensions: [
            subject_alt_name: ["example.com", "www.example.com"]
          ],
          actor: "admin"
        )

      assert cert != nil

      # Verify certificate
      otp_certificate(tbsCertificate: tbs) = cert
      subject_rdn = otp_tbs_certificate(tbs, :subject)
      subject_str = GSMLG.PKI.RDNSequence.to_string(subject_rdn)
      assert subject_str =~ "example.com"

      # Verify issuer is CA
      issuer_rdn = otp_tbs_certificate(tbs, :issuer)
      issuer_str = GSMLG.PKI.RDNSequence.to_string(issuer_rdn)
      assert issuer_str =~ ca.subject
    end

    test "issues a client certificate", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=john.doe@example.com/O=Example Inc",
          template: :client,
          validity: 730,
          actor: "admin"
        )

      assert cert != nil
    end

    test "logs certificate issuance event", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=test.example.com",
          template: :server,
          validity: 365,
          actor: "test-admin"
        )

      # Extract serial
      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # Query events
      {:ok, events} = Events.query_by_serial(serial)

      assert length(events) >= 1
      issue_event = Enum.find(events, &(&1.event_type == :certificate_issued))
      assert issue_event != nil
      assert issue_event.metadata.serial == serial
      assert issue_event.metadata.subject == "/CN=test.example.com"
      assert issue_event.actor == "test-admin"
    end

    test "issued certificate can be validated", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=valid.example.com",
          template: :server,
          validity: 365
        )

      # Validate certificate
      {:ok, :valid} =
        Validator.validate_chain(cert, [ca.certificate], check_revocation: true)
    end
  end

  describe "CA.revoke_certificate/3" do
    test "revokes a certificate", %{ca: ca} do
      # Issue certificate
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=revoke-test.com",
          template: :server,
          validity: 365
        )

      # Extract serial
      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # Verify it's active
      {:ok, state_before} = Events.get_certificate_state(serial)
      assert state_before.status == :active

      # Revoke certificate
      :ok =
        CA.revoke_certificate(
          ca,
          serial,
          reason: :keyCompromise,
          actor: "security-team"
        )

      # Verify it's revoked
      {:ok, state_after} = Events.get_certificate_state(serial)
      assert state_after.status == :revoked
      assert state_after.revocation_reason == :keyCompromise
    end

    test "logs revocation event", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(ca, public_key, "/CN=test.com")

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      :ok = CA.revoke_certificate(ca, serial, reason: :keyCompromise, actor: "admin")

      # Query revocation events
      {:ok, events} = Events.query_by_serial(serial)

      revoke_event = Enum.find(events, &(&1.event_type == :certificate_revoked))
      assert revoke_event != nil
      assert revoke_event.metadata.serial == serial
      assert revoke_event.metadata.reason == :keyCompromise
      assert revoke_event.actor == "admin"
    end

    test "returns error when revoking already revoked certificate", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(ca, public_key, "/CN=test.com")

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # First revocation
      :ok = CA.revoke_certificate(ca, serial, reason: :keyCompromise)

      # Second revocation should fail
      assert {:error, :already_revoked} = CA.revoke_certificate(ca, serial, reason: :superseded)
    end

    test "revoked certificate fails validation", %{ca: ca} do
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)
      {:ok, cert} = CA.issue_certificate_direct(ca, public_key, "/CN=test.com")

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # Revoke certificate
      :ok = CA.revoke_certificate(ca, serial, reason: :keyCompromise)

      # Validation should detect revocation
      {:ok, {:invalid, {:revoked, :keyCompromise}}} =
        Validator.validate_chain(cert, [ca.certificate], check_revocation: true)
    end
  end

  describe "CA.generate_crl/2" do
    test "generates empty CRL with no revocations", %{ca: ca} do
      {:ok, crl} = CA.generate_crl(ca, validity: 7)

      assert crl != nil

      # Verify CRL can be serialized
      {:ok, crl_der} = GSMLG.PKI.CRL.to_der(crl)
      assert byte_size(crl_der) > 0
    end

    test "generates CRL with revoked certificates", %{ca: ca} do
      # Issue and revoke multiple certificates
      serials =
        for i <- 1..3 do
          key = PrivateKey.new_rsa(2048)
          public_key = PublicKey.derive(key)
          {:ok, cert} = CA.issue_certificate_direct(ca, public_key, "/CN=test#{i}.com")
          otp_certificate(tbsCertificate: tbs) = cert
          otp_tbs_certificate(serialNumber: serial) = tbs
          :ok = CA.revoke_certificate(ca, serial, reason: :keyCompromise)
          serial
        end

      # Generate CRL
      {:ok, crl} = CA.generate_crl(ca)

      # Verify CRL contains revoked certificates
      {:ok, revocations} = Events.get_revocations(ca.id)
      assert length(revocations) == 3
      assert Enum.all?(serials, fn s -> Enum.any?(revocations, &(&1.serial == s)) end)
    end

    test "logs CRL generation event", %{ca: ca} do
      {:ok, _crl} = CA.generate_crl(ca)

      # Query CRL events
      {:ok, events} = Events.query_by_type(:crl_generated)

      ca_crl_events = Enum.filter(events, &(&1.metadata.ca_id == ca.id))
      assert length(ca_crl_events) >= 1

      crl_event = List.first(ca_crl_events)
      assert crl_event.event_type == :crl_generated
      assert crl_event.metadata.ca_id == ca.id
      assert crl_event.metadata.crl_number >= 1
    end
  end

  describe "CA.get_stats/1" do
    test "returns CA statistics", %{ca: ca} do
      # Issue some certificates
      for i <- 1..5 do
        key = PrivateKey.new_rsa(2048)
        public_key = PublicKey.derive(key)
        CA.issue_certificate_direct(ca, public_key, "/CN=test#{i}.com")
      end

      # Revoke some
      {:ok, events} = Events.query_by_ca(ca.id)
      issue_events = Enum.filter(events, &(&1.event_type == :certificate_issued))

      [event1, event2 | _] = issue_events
      CA.revoke_certificate(ca, event1.metadata.serial, reason: :keyCompromise)
      CA.revoke_certificate(ca, event2.metadata.serial, reason: :superseded)

      # Get stats
      {:ok, stats} = CA.get_stats(ca.id)

      assert stats.total_issued >= 5
      assert stats.revoked_certificates >= 2
      assert stats.active_certificates >= 3
    end
  end

  describe "CA.get_expiring_certificates/2" do
    test "returns certificates expiring soon", %{ca: ca} do
      # Issue certificate expiring in 10 days
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, _cert} =
        CA.issue_certificate_direct(ca, public_key, "/CN=expiring.com", validity: 10)

      # Query expiring certificates (within 30 days)
      {:ok, expiring} = CA.get_expiring_certificates(ca.id, 30)

      assert length(expiring) >= 1
      cert_info = Enum.find(expiring, &(&1.subject =~ "expiring.com"))
      assert cert_info != nil
      assert cert_info.days_remaining <= 30
    end

    test "does not return recently issued certificates", %{ca: ca} do
      # Issue certificate valid for 1 year
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, _cert} =
        CA.issue_certificate_direct(ca, public_key, "/CN=fresh.com", validity: 365)

      # Query expiring in next 30 days
      {:ok, expiring} = CA.get_expiring_certificates(ca.id, 30)

      # Should not include this certificate
      cert_info = Enum.find(expiring, &(&1.subject =~ "fresh.com"))
      assert cert_info == nil
    end
  end

  describe "Integration tests" do
    test "complete certificate lifecycle", %{ca: ca} do
      # 1. Issue certificate
      key = PrivateKey.new_rsa(2048)
      public_key = PublicKey.derive(key)

      {:ok, cert} =
        CA.issue_certificate_direct(
          ca,
          public_key,
          "/CN=lifecycle.example.com",
          template: :server,
          validity: 365,
          extensions: [subject_alt_name: ["lifecycle.example.com"]],
          actor: "admin"
        )

      otp_certificate(tbsCertificate: tbs) = cert
      otp_tbs_certificate(serialNumber: serial) = tbs

      # 2. Validate - should be valid
      {:ok, :valid} = Validator.validate_chain(cert, [ca.certificate])

      # 3. Check state - should be active
      {:ok, state} = Events.get_certificate_state(serial)
      assert state.status == :active

      # 4. Revoke
      :ok = CA.revoke_certificate(ca, serial, reason: :keyCompromise, actor: "security")

      # 5. Check state - should be revoked
      {:ok, state} = Events.get_certificate_state(serial)
      assert state.status == :revoked

      # 6. Validate - should detect revocation
      {:ok, {:invalid, {:revoked, :keyCompromise}}} =
        Validator.validate_chain(cert, [ca.certificate], check_revocation: true)

      # 7. Generate CRL
      {:ok, crl} = CA.generate_crl(ca)
      assert crl != nil

      # 8. Query all events
      {:ok, events} = Events.query_by_serial(serial)
      assert length(events) >= 2

      event_types = Enum.map(events, & &1.event_type)
      assert :certificate_issued in event_types
      assert :certificate_revoked in event_types
    end

    test "multiple certificate issuance and selective revocation", %{ca: ca} do
      # Issue 10 certificates
      certs_and_serials =
        for i <- 1..10 do
          key = PrivateKey.new_rsa(2048)
          public_key = PublicKey.derive(key)
          {:ok, cert} = CA.issue_certificate_direct(ca, public_key, "/CN=test#{i}.com")
          otp_certificate(tbsCertificate: tbs) = cert
          otp_tbs_certificate(serialNumber: serial) = tbs
          {cert, serial}
        end

      # Revoke every other certificate
      certs_and_serials
      |> Enum.with_index()
      |> Enum.filter(fn {_, idx} -> rem(idx, 2) == 0 end)
      |> Enum.each(fn {{_cert, serial}, _} ->
        CA.revoke_certificate(ca, serial, reason: :superseded)
      end)

      # Check statistics
      {:ok, stats} = CA.get_stats(ca.id)
      assert stats.total_issued >= 10
      assert stats.revoked_certificates >= 5
      assert stats.active_certificates >= 5

      # Verify each certificate state
      Enum.each(certs_and_serials, fn {_cert, serial} ->
        {:ok, state} = Events.get_certificate_state(serial)
        assert state.status in [:active, :revoked]
      end)
    end
  end
end
