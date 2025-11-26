defmodule GSMLG.PKI.Schema.CertificateAuthorityTest do
  use GSMLG.DataCase, async: true

  alias GSMLG.PKI.Schema.CertificateAuthority

  @valid_attrs %{
    id: "ca:test-123",
    subject: "/CN=Test CA/O=Test Org/C=US",
    serial: "abc123def456",
    certificate_pem: "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----",
    private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----",
    public_key_pem: "-----BEGIN RSA PUBLIC KEY-----\ntest\n-----END RSA PUBLIC KEY-----",
    not_before: ~U[2025-01-01 00:00:00Z],
    not_after: ~U[2035-01-01 00:00:00Z]
  }

  describe "changeset/2" do
    test "valid changeset with required fields" do
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, @valid_attrs)

      assert changeset.valid?
      assert changeset.changes.subject == "/CN=Test CA/O=Test Org/C=US"
      assert changeset.changes.status == "active"
      assert changeset.changes.key_type == "rsa"
    end

    test "requires id field" do
      attrs = Map.delete(@valid_attrs, :id)
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires subject field" do
      attrs = Map.delete(@valid_attrs, :subject)
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{subject: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires certificate_pem field" do
      attrs = Map.delete(@valid_attrs, :certificate_pem)
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{certificate_pem: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires validity period fields" do
      attrs = @valid_attrs |> Map.delete(:not_before) |> Map.delete(:not_after)
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{not_before: _, not_after: _} = errors_on(changeset)
    end

    test "validates not_after is after not_before" do
      attrs =
        Map.merge(@valid_attrs, %{
          not_before: ~U[2035-01-01 00:00:00Z],
          not_after: ~U[2025-01-01 00:00:00Z]
        })

      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{not_after: ["must be after not_before"]} = errors_on(changeset)
    end

    test "validates status is in allowed values" do
      attrs = Map.put(@valid_attrs, :status, "invalid_status")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts active status" do
      attrs = Map.put(@valid_attrs, :status, "active")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts revoked status" do
      attrs = Map.put(@valid_attrs, :status, "revoked")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts expired status" do
      attrs = Map.put(@valid_attrs, :status, "expired")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "validates key_type is in allowed values" do
      attrs = Map.put(@valid_attrs, :key_type, "invalid_type")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{key_type: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts rsa key type" do
      attrs = Map.put(@valid_attrs, :key_type, "rsa")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts ecdsa key type" do
      attrs = Map.put(@valid_attrs, :key_type, "ecdsa")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts ed25519 key type" do
      attrs = Map.put(@valid_attrs, :key_type, "ed25519")
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end
  end

  describe "key_algorithm_details validation" do
    test "accepts valid RSA key algorithm details" do
      attrs =
        Map.merge(@valid_attrs, %{
          key_type: "rsa",
          key_algorithm_details: %{"modulus_bits" => 4096, "public_exponent" => 65537}
        })

      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "rejects RSA key with invalid modulus_bits" do
      attrs =
        Map.merge(@valid_attrs, %{
          key_type: "rsa",
          key_algorithm_details: %{"modulus_bits" => 1024}
        })

      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      refute changeset.valid?
      assert %{key_algorithm_details: _} = errors_on(changeset)
    end

    test "accepts valid ECDSA key algorithm details" do
      attrs =
        Map.merge(@valid_attrs, %{
          key_type: "ecdsa",
          key_algorithm_details: %{"curve_name" => "secp384r1", "key_size_bits" => 384}
        })

      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts valid Ed25519 key algorithm details" do
      attrs =
        Map.merge(@valid_attrs, %{
          key_type: "ed25519",
          key_algorithm_details: %{"curve" => "ed25519", "key_size_bits" => 256}
        })

      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end

    test "accepts nil key_algorithm_details" do
      attrs = Map.put(@valid_attrs, :key_algorithm_details, nil)
      changeset = CertificateAuthority.changeset(%CertificateAuthority{}, attrs)

      assert changeset.valid?
    end
  end

  describe "active?/1" do
    test "returns true for active CA with future expiry" do
      ca = %CertificateAuthority{
        status: "active",
        not_after: DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)
      }

      assert CertificateAuthority.active?(ca)
    end

    test "returns false for revoked CA" do
      ca = %CertificateAuthority{
        status: "revoked",
        not_after: DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)
      }

      refute CertificateAuthority.active?(ca)
    end

    test "returns false for expired CA" do
      ca = %CertificateAuthority{
        status: "active",
        not_after: DateTime.add(DateTime.utc_now(), -1 * 24 * 3600, :second)
      }

      refute CertificateAuthority.active?(ca)
    end
  end

  describe "expired?/1" do
    test "returns true for CA with past expiry date" do
      ca = %CertificateAuthority{
        not_after: DateTime.add(DateTime.utc_now(), -1 * 24 * 3600, :second)
      }

      assert CertificateAuthority.expired?(ca)
    end

    test "returns false for CA with future expiry date" do
      ca = %CertificateAuthority{
        not_after: DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)
      }

      refute CertificateAuthority.expired?(ca)
    end
  end

  describe "increment_sequence_changeset/1" do
    test "increments current_sequence by 1" do
      ca = %CertificateAuthority{current_sequence: 5}
      changeset = CertificateAuthority.increment_sequence_changeset(ca)

      assert changeset.changes.current_sequence == 6
    end

    test "increments from 0" do
      ca = %CertificateAuthority{current_sequence: 0}
      changeset = CertificateAuthority.increment_sequence_changeset(ca)

      assert changeset.changes.current_sequence == 1
    end
  end
end
