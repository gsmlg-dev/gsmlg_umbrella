defmodule GSMLG.AdminWeb.PKILive.CALive.FormDataTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.PKILive.CALive.FormData

  @valid_attrs %{
    "common_name" => "Test CA",
    "organization" => "Test Org",
    "country" => "US",
    "key_type" => "rsa",
    "key_size" => 4096,
    "validity_start" => ~U[2025-01-01 00:00:00Z],
    "validity_end" => ~U[2035-01-01 00:00:00Z],
    "encrypt_key" => false
  }

  describe "changeset/2 with valid data" do
    test "accepts valid attributes" do
      changeset = FormData.changeset(%FormData{}, @valid_attrs)

      assert changeset.valid?
    end

    test "sets default values" do
      changeset = FormData.changeset(%FormData{}, %{})

      assert changeset.changes[:key_type] == "rsa" || changeset.data.key_type == "rsa"
      assert changeset.changes[:key_size] == 4096 || changeset.data.key_size == 4096
      assert changeset.changes[:encrypt_key] == false || changeset.data.encrypt_key == false
    end
  end

  describe "common_name validation" do
    test "requires common_name" do
      attrs = Map.delete(@valid_attrs, "common_name")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{common_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates minimum length of 1 character" do
      attrs = Map.put(@valid_attrs, "common_name", "")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
    end

    test "validates maximum length of 64 characters" do
      attrs = Map.put(@valid_attrs, "common_name", String.duplicate("a", 65))
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{common_name: ["should be at most 64 character(s)"]} = errors_on(changeset)
    end
  end

  describe "country code validation" do
    test "accepts valid 2-letter uppercase country code" do
      attrs = Map.put(@valid_attrs, "country", "US")
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "accepts GB as country code" do
      attrs = Map.put(@valid_attrs, "country", "GB")
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "rejects lowercase country code" do
      attrs = Map.put(@valid_attrs, "country", "us")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{country: ["must be uppercase (e.g., US, GB, CN)"]} = errors_on(changeset)
    end

    test "rejects country code longer than 2 characters" do
      attrs = Map.put(@valid_attrs, "country", "USA")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{country: ["must be exactly 2 characters"]} = errors_on(changeset)
    end

    test "rejects country code shorter than 2 characters" do
      attrs = Map.put(@valid_attrs, "country", "U")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
    end

    test "accepts empty country code" do
      attrs = Map.put(@valid_attrs, "country", "")
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "accepts nil country code" do
      attrs = Map.put(@valid_attrs, "country", nil)
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end
  end

  describe "key configuration validation" do
    test "has default key_type when not provided" do
      # key_type has a default value of "rsa", so changeset is valid
      attrs = Map.delete(@valid_attrs, "key_type")
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
      assert changeset.changes[:key_type] == "rsa" || changeset.data.key_type == "rsa"
    end

    test "validates key_type is in allowed values" do
      attrs = Map.put(@valid_attrs, "key_type", "invalid")
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{key_type: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts rsa key type" do
      attrs = Map.put(@valid_attrs, "key_type", "rsa")
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "accepts ecdsa key type" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "ecdsa", "key_size" => 256})
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "accepts ed25519 key type" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "ed25519", "key_size" => 256})
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "validates RSA key size is in allowed values" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "rsa", "key_size" => 1024})
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{key_size: _} = errors_on(changeset)
    end

    test "accepts RSA 2048 key size" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "rsa", "key_size" => 2048})
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "validates ECDSA key size is in allowed values" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "ecdsa", "key_size" => 512})
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
    end

    test "accepts ECDSA 384 key size" do
      attrs = Map.merge(@valid_attrs, %{"key_type" => "ecdsa", "key_size" => 384})
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end
  end

  describe "validity period validation" do
    test "validates validity_end is after validity_start" do
      attrs =
        Map.merge(@valid_attrs, %{
          "validity_start" => ~U[2035-01-01 00:00:00Z],
          "validity_end" => ~U[2025-01-01 00:00:00Z]
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{validity_end: ["must be after validity start"]} = errors_on(changeset)
    end

    test "warns about validity period exceeding 20 years" do
      attrs =
        Map.merge(@valid_attrs, %{
          "validity_start" => ~U[2025-01-01 00:00:00Z],
          "validity_end" => ~U[2050-01-01 00:00:00Z]
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{validity_end: _} = errors_on(changeset)
      assert Enum.any?(errors_on(changeset).validity_end, &String.contains?(&1, "20 years"))
    end

    test "accepts validity period under 20 years" do
      attrs =
        Map.merge(@valid_attrs, %{
          "validity_start" => ~U[2025-01-01 00:00:00Z],
          "validity_end" => ~U[2035-01-01 00:00:00Z]
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end
  end

  describe "password validation when encryption enabled" do
    test "requires password when encrypt_key is true" do
      attrs = Map.put(@valid_attrs, "encrypt_key", true)
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{password: _} = errors_on(changeset)
    end

    test "requires password_confirmation when encrypt_key is true" do
      attrs = Map.merge(@valid_attrs, %{"encrypt_key" => true, "password" => "test123"})
      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{password_confirmation: _} = errors_on(changeset)
    end

    test "validates password minimum length of 12 characters" do
      attrs =
        Map.merge(@valid_attrs, %{
          "encrypt_key" => true,
          "password" => "short",
          "password_confirmation" => "short"
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      # Password validation may return multiple errors (length + complexity)
      errors = errors_on(changeset)
      assert "must be at least 12 characters" in errors[:password]
    end

    test "validates password contains uppercase, lowercase, and digit" do
      attrs =
        Map.merge(@valid_attrs, %{
          "encrypt_key" => true,
          "password" => "alllowercase",
          "password_confirmation" => "alllowercase"
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{password: _} = errors_on(changeset)
    end

    test "validates password confirmation matches" do
      attrs =
        Map.merge(@valid_attrs, %{
          "encrypt_key" => true,
          "password" => "ValidPassword123",
          "password_confirmation" => "DifferentPassword123"
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      refute changeset.valid?
      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "accepts valid password when encrypt_key is true" do
      attrs =
        Map.merge(@valid_attrs, %{
          "encrypt_key" => true,
          "password" => "SecurePassword123",
          "password_confirmation" => "SecurePassword123"
        })

      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end

    test "does not require password when encrypt_key is false" do
      attrs = Map.put(@valid_attrs, "encrypt_key", false)
      changeset = FormData.changeset(%FormData{}, attrs)

      assert changeset.valid?
    end
  end

  describe "build_subject_dn/1" do
    test "builds DN string with all fields" do
      form_data = %FormData{
        common_name: "Test CA",
        organization: "Test Org",
        organizational_unit: "IT",
        country: "US",
        state: "California",
        locality: "San Francisco"
      }

      dn = FormData.build_subject_dn(form_data)

      assert dn == "/CN=Test CA/O=Test Org/OU=IT/C=US/ST=California/L=San Francisco"
    end

    test "builds DN string with only required fields" do
      form_data = %FormData{
        common_name: "Test CA"
      }

      dn = FormData.build_subject_dn(form_data)

      assert dn == "/CN=Test CA"
    end

    test "omits empty optional fields" do
      form_data = %FormData{
        common_name: "Test CA",
        organization: "Test Org",
        organizational_unit: "",
        country: "US",
        state: nil,
        locality: "   "
      }

      dn = FormData.build_subject_dn(form_data)

      assert dn == "/CN=Test CA/O=Test Org/C=US"
    end

    test "maintains field order: CN, O, OU, C, ST, L" do
      form_data = %FormData{
        common_name: "CA",
        organization: "Org",
        organizational_unit: "Unit",
        country: "GB",
        state: "State",
        locality: "City"
      }

      dn = FormData.build_subject_dn(form_data)

      assert dn == "/CN=CA/O=Org/OU=Unit/C=GB/ST=State/L=City"
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
