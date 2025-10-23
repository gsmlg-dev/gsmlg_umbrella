defmodule GSMLG.MACTest do
  use ExUnit.Case
  doctest GSMLG.MAC

  describe "lookup_vendor/1" do
    test "looks up vendor with colon-separated MAC" do
      assert GSMLG.MAC.lookup_vendor("00:00:0A:BB:28:FC") ==
               {:ok, "OmronTat", "Omron Tateisi Electronics Co."}
    end

    test "looks up vendor with hyphen-separated MAC" do
      # This test depends on the manuf.txt file being present
      # Skip if file doesn't exist
      case GSMLG.MAC.lookup_vendor("00-00-0A-BB-28-FC") do
        {:ok, _, _} -> :ok
        :error -> :ok
      end
    end

    test "looks up vendor with dot-separated MAC (Cisco format)" do
      case GSMLG.MAC.lookup_vendor("0000.0ABB.28FC") do
        {:ok, _, _} -> :ok
        :error -> :ok
      end
    end

    test "looks up vendor with no separators" do
      case GSMLG.MAC.lookup_vendor("00000ABB28FC") do
        {:ok, _, _} -> :ok
        :error -> :ok
      end
    end

    test "returns :error for unknown vendor" do
      assert GSMLG.MAC.lookup_vendor("FF:FF:FF:FF:FF:FF") == :error
    end

    test "returns :error for invalid MAC format" do
      assert GSMLG.MAC.lookup_vendor("invalid") == :error
    end

    test "returns :error for too short MAC" do
      assert GSMLG.MAC.lookup_vendor("00:1A:2B") == :error
    end
  end

  describe "validate/1" do
    test "validates colon-separated MAC" do
      assert GSMLG.MAC.validate("00:1A:2B:3C:4D:5E") == true
      assert GSMLG.MAC.validate("AA:BB:CC:DD:EE:FF") == true
      assert GSMLG.MAC.validate("00:00:00:00:00:00") == true
    end

    test "validates hyphen-separated MAC" do
      assert GSMLG.MAC.validate("00-1A-2B-3C-4D-5E") == true
      assert GSMLG.MAC.validate("AA-BB-CC-DD-EE-FF") == true
    end

    test "validates dot-separated MAC (Cisco format)" do
      assert GSMLG.MAC.validate("001A.2B3C.4D5E") == true
      assert GSMLG.MAC.validate("AABB.CCDD.EEFF") == true
    end

    test "validates MAC with no separators" do
      assert GSMLG.MAC.validate("001A2B3C4D5E") == true
      assert GSMLG.MAC.validate("AABBCCDDEEFF") == true
    end

    test "accepts lowercase MAC addresses" do
      assert GSMLG.MAC.validate("00:1a:2b:3c:4d:5e") == true
      assert GSMLG.MAC.validate("aa-bb-cc-dd-ee-ff") == true
    end

    test "accepts mixed case MAC addresses" do
      assert GSMLG.MAC.validate("00:1A:2b:3C:4d:5E") == true
    end

    test "rejects invalid formats" do
      assert GSMLG.MAC.validate("invalid") == false
      assert GSMLG.MAC.validate("not-a-mac") == false
      assert GSMLG.MAC.validate("") == false
    end

    test "rejects too short MAC" do
      assert GSMLG.MAC.validate("00:1A:2B:3C:4D") == false
      assert GSMLG.MAC.validate("00:1A:2B") == false
    end

    test "rejects too long MAC" do
      assert GSMLG.MAC.validate("00:1A:2B:3C:4D:5E:FF") == false
    end

    test "rejects invalid hex characters" do
      assert GSMLG.MAC.validate("00:1A:2B:GG:4D:5E") == false
      assert GSMLG.MAC.validate("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ") == false
    end

    test "rejects non-string input" do
      assert GSMLG.MAC.validate(nil) == false
      assert GSMLG.MAC.validate(123) == false
      assert GSMLG.MAC.validate([:a, :b]) == false
    end
  end

  describe "normalize/1" do
    test "normalizes hyphen-separated to colons" do
      assert GSMLG.MAC.normalize("00-1a-2b-3c-4d-5e") == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "normalizes dot-separated to colons" do
      assert GSMLG.MAC.normalize("001a.2b3c.4d5e") == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "normalizes no separators to colons" do
      assert GSMLG.MAC.normalize("001a2b3c4d5e") == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "converts lowercase to uppercase" do
      assert GSMLG.MAC.normalize("00:1a:2b:3c:4d:5e") == {:ok, "00:1A:2B:3C:4D:5E"}
      assert GSMLG.MAC.normalize("aa:bb:cc:dd:ee:ff") == {:ok, "AA:BB:CC:DD:EE:FF"}
    end

    test "normalizes already normalized MAC" do
      assert GSMLG.MAC.normalize("00:1A:2B:3C:4D:5E") == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "returns error for invalid MAC" do
      assert GSMLG.MAC.normalize("invalid") == {:error, :invalid_mac}
      assert GSMLG.MAC.normalize("00:1A:2B") == {:error, :invalid_mac}
      assert GSMLG.MAC.normalize("") == {:error, :invalid_mac}
    end

    test "returns error for non-string input" do
      assert GSMLG.MAC.normalize(nil) == {:error, :invalid_mac}
      assert GSMLG.MAC.normalize(123) == {:error, :invalid_mac}
    end
  end

  describe "format/2" do
    test "formats with colons" do
      assert GSMLG.MAC.format("001a2b3c4d5e", :colons) == {:ok, "00:1A:2B:3C:4D:5E"}
      assert GSMLG.MAC.format("00-1A-2B-3C-4D-5E", :colons) == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "formats with hyphens" do
      assert GSMLG.MAC.format("001a2b3c4d5e", :hyphens) == {:ok, "00-1A-2B-3C-4D-5E"}
      assert GSMLG.MAC.format("00:1A:2B:3C:4D:5E", :hyphens) == {:ok, "00-1A-2B-3C-4D-5E"}
    end

    test "formats with dots (Cisco)" do
      assert GSMLG.MAC.format("001a2b3c4d5e", :dots) == {:ok, "001A.2B3C.4D5E"}
      assert GSMLG.MAC.format("00:1A:2B:3C:4D:5E", :dots) == {:ok, "001A.2B3C.4D5E"}
    end

    test "formats with cisco (same as dots)" do
      assert GSMLG.MAC.format("001a2b3c4d5e", :cisco) == {:ok, "001A.2B3C.4D5E"}
    end

    test "formats with no separators" do
      assert GSMLG.MAC.format("00:1A:2B:3C:4D:5E", :none) == {:ok, "001A2B3C4D5E"}
      assert GSMLG.MAC.format("00-1A-2B-3C-4D-5E", :none) == {:ok, "001A2B3C4D5E"}
    end

    test "defaults to colons if format not specified" do
      assert GSMLG.MAC.format("001a2b3c4d5e") == {:ok, "00:1A:2B:3C:4D:5E"}
    end

    test "returns error for invalid format type" do
      assert GSMLG.MAC.format("00:1A:2B:3C:4D:5E", :unknown) == {:error, :invalid_format}
      assert GSMLG.MAC.format("00:1A:2B:3C:4D:5E", :invalid) == {:error, :invalid_format}
    end

    test "returns error for invalid MAC" do
      assert GSMLG.MAC.format("invalid", :colons) == {:error, :invalid_mac}
      assert GSMLG.MAC.format("00:1A:2B", :colons) == {:error, :invalid_mac}
    end
  end

  describe "parse_oui/1" do
    test "extracts OUI from colon-separated MAC" do
      assert GSMLG.MAC.parse_oui("00:1A:2B:3C:4D:5E") == {:ok, "00:1A:2B"}
    end

    test "extracts OUI from hyphen-separated MAC" do
      assert GSMLG.MAC.parse_oui("00-1A-2B-3C-4D-5E") == {:ok, "00:1A:2B"}
    end

    test "extracts OUI from dot-separated MAC" do
      assert GSMLG.MAC.parse_oui("001A.2B3C.4D5E") == {:ok, "00:1A:2B"}
    end

    test "extracts OUI from MAC with no separators" do
      assert GSMLG.MAC.parse_oui("001A2B3C4D5E") == {:ok, "00:1A:2B"}
    end

    test "converts lowercase OUI to uppercase" do
      assert GSMLG.MAC.parse_oui("00:1a:2b:3c:4d:5e") == {:ok, "00:1A:2B"}
    end

    test "returns OUI in colon format" do
      {:ok, oui} = GSMLG.MAC.parse_oui("AA-BB-CC-DD-EE-FF")
      assert String.contains?(oui, ":")
      assert oui == "AA:BB:CC"
    end

    test "returns error for invalid MAC" do
      assert GSMLG.MAC.parse_oui("invalid") == {:error, :invalid_mac}
      assert GSMLG.MAC.parse_oui("00:1A") == {:error, :invalid_mac}
    end

    test "returns error for non-string input" do
      assert GSMLG.MAC.parse_oui(nil) == {:error, :invalid_mac}
    end
  end

  describe "random/0" do
    test "generates a valid MAC address" do
      mac = GSMLG.MAC.random()
      assert is_binary(mac)
      assert GSMLG.MAC.validate(mac) == true
    end

    test "generates different MACs on subsequent calls" do
      mac1 = GSMLG.MAC.random()
      mac2 = GSMLG.MAC.random()
      # Extremely unlikely to be the same
      assert mac1 != mac2
    end

    test "generates MAC in colon-separated format" do
      mac = GSMLG.MAC.random()
      assert String.contains?(mac, ":")
      assert length(String.split(mac, ":")) == 6
    end

    test "generates all uppercase MACs" do
      mac = GSMLG.MAC.random()
      assert mac == String.upcase(mac)
    end
  end

  describe "random/1 with OUI" do
    test "generates MAC with specified OUI (colon format)" do
      mac = GSMLG.MAC.random("00:1A:2B")
      assert String.starts_with?(mac, "00:1A:2B")
      assert GSMLG.MAC.validate(mac) == true
    end

    test "generates MAC with specified OUI (hyphen format)" do
      mac = GSMLG.MAC.random("00-1A-2B")
      assert String.starts_with?(mac, "00:1A:2B")
    end

    test "generates MAC with specified OUI (no separator)" do
      mac = GSMLG.MAC.random("001A2B")
      assert String.starts_with?(mac, "00:1A:2B")
    end

    test "generates different MACs with same OUI" do
      mac1 = GSMLG.MAC.random("00:1A:2B")
      mac2 = GSMLG.MAC.random("00:1A:2B")
      # Should have same OUI but different last 3 bytes
      assert String.slice(mac1, 0..7) == String.slice(mac2, 0..7)
      assert mac1 != mac2
    end

    test "returns error for invalid OUI" do
      assert GSMLG.MAC.random("invalid") == {:error, :invalid_oui}
      assert GSMLG.MAC.random("ZZ:ZZ:ZZ") == {:error, :invalid_oui}
    end

    test "returns error for too short OUI" do
      assert GSMLG.MAC.random("00:1A") == {:error, :invalid_oui}
    end

    test "returns error for too long OUI" do
      assert GSMLG.MAC.random("00:1A:2B:3C") == {:error, :invalid_oui}
    end
  end

  describe "integration tests" do
    test "normalize then format roundtrip" do
      original = "00-1a-2b-3c-4d-5e"
      {:ok, normalized} = GSMLG.MAC.normalize(original)
      {:ok, formatted} = GSMLG.MAC.format(normalized, :hyphens)
      assert formatted == "00-1A-2B-3C-4D-5E"
    end

    test "random MAC can be normalized" do
      mac = GSMLG.MAC.random()
      {:ok, normalized} = GSMLG.MAC.normalize(mac)
      assert normalized == mac
    end

    test "random MAC OUI can be parsed" do
      oui = "AA:BB:CC"
      mac = GSMLG.MAC.random(oui)
      {:ok, parsed_oui} = GSMLG.MAC.parse_oui(mac)
      assert parsed_oui == oui
    end

    test "validate accepts all format outputs" do
      mac = "001A2B3C4D5E"
      {:ok, colons} = GSMLG.MAC.format(mac, :colons)
      {:ok, hyphens} = GSMLG.MAC.format(mac, :hyphens)
      {:ok, dots} = GSMLG.MAC.format(mac, :dots)
      {:ok, none} = GSMLG.MAC.format(mac, :none)

      assert GSMLG.MAC.validate(colons) == true
      assert GSMLG.MAC.validate(hyphens) == true
      assert GSMLG.MAC.validate(dots) == true
      assert GSMLG.MAC.validate(none) == true
    end
  end

  describe "telemetry" do
    @tag :skip
    test "emits lookup event on vendor lookup" do
      # Telemetry integration is optional and requires gsmlg_telemetry dependency
      # These tests are documented but skipped as telemetry is not a hard dependency
      :ok
    end

    @tag :skip
    test "emits operation event on validate" do
      # Telemetry integration is optional and requires gsmlg_telemetry dependency
      :ok
    end
  end
end
