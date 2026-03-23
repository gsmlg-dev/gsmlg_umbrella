defmodule GSMLG.ApiProvider.EncryptedMapTest do
  use ExUnit.Case, async: true

  alias GSMLG.ApiProvider.EncryptedMap

  describe "cast/1" do
    test "accepts maps" do
      assert {:ok, %{key: "val"}} = EncryptedMap.cast(%{key: "val"})
    end

    test "rejects non-maps" do
      assert :error = EncryptedMap.cast("string")
      assert :error = EncryptedMap.cast(123)
      assert :error = EncryptedMap.cast(nil)
    end
  end

  describe "dump/1 and load/1 round-trip" do
    test "encrypts and decrypts a map" do
      original = %{api_key: "sk-secret", extra: "data"}
      assert {:ok, encrypted} = EncryptedMap.dump(original)
      assert String.starts_with?(encrypted, "v1:")
      assert {:ok, decrypted} = EncryptedMap.load(encrypted)
      assert decrypted == original
    end

    test "each dump produces a unique ciphertext (random IV)" do
      map = %{token: "abc"}
      assert {:ok, enc1} = EncryptedMap.dump(map)
      assert {:ok, enc2} = EncryptedMap.dump(map)
      refute enc1 == enc2
    end

    test "nil passes through" do
      assert {:ok, nil} = EncryptedMap.dump(nil)
      assert {:ok, nil} = EncryptedMap.load(nil)
    end
  end

  describe "load/1 error handling" do
    test "returns error for tampered ciphertext" do
      assert {:ok, encrypted} = EncryptedMap.dump(%{key: "val"})
      tampered = String.replace(encrypted, "v1:", "v1:AAA")
      assert {:error, :decryption_failed} = EncryptedMap.load(tampered)
    end

    test "returns error for non-prefixed binary" do
      assert {:error, :decryption_failed} = EncryptedMap.load("not-encrypted")
    end
  end
end
