defmodule GSMLG.Content.EncryptedString do
  @moduledoc """
  Custom Ecto type that transparently encrypts string values at rest using AES-256-GCM.

  Encrypted values are stored as `"v1:<base64(iv <> tag <> ciphertext)>"`.
  Plain-text values written before encryption was introduced are returned as-is
  (migration path: they will be re-encrypted on the next write).

  Configure the encryption secret in config:

      config :gsmlg, :translation_encryption_key, System.get_env("GSMLG_TRANSLATION_KEY")
  """

  use Ecto.Type

  @prefix "v1:"

  def type, do: :string

  def cast(value), do: {:ok, value}

  def dump(nil), do: {:ok, nil}
  def dump(""), do: {:ok, ""}

  def dump(value) when is_binary(value) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, "", true)
    encoded = @prefix <> Base.encode64(iv <> tag <> ciphertext)
    {:ok, encoded}
  end

  def dump(_), do: :error

  def load(nil), do: {:ok, nil}
  def load(""), do: {:ok, ""}

  def load(@prefix <> encoded) do
    key = encryption_key()

    with {:ok, decoded} <- Base.decode64(encoded),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- decoded,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      {:ok, plain}
    else
      _ -> {:error, :decryption_failed}
    end
  end

  # Legacy plain-text value (written before this type was introduced): pass through.
  def load(value) when is_binary(value), do: {:ok, value}

  defp encryption_key do
    secret =
      Application.get_env(:gsmlg, :translation_encryption_key) ||
        raise "GSMLG :translation_encryption_key not configured. Set GSMLG_TRANSLATION_KEY env var."

    :crypto.hash(:sha256, secret)
  end
end
