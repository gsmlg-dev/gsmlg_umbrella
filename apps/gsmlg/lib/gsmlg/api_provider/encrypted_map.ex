defmodule GSMLG.ApiProvider.EncryptedMap do
  @moduledoc """
  Custom Ecto type that transparently encrypts map values at rest using AES-256-GCM.

  The map is JSON-encoded then encrypted. Encrypted values are stored as
  `"v1:<base64(iv <> tag <> ciphertext)>"` in a text column.

  Configure the encryption secret via environment variable:

      GSMLG_API_PROVIDER_KEY=your-secret-key

  When the key is not configured the service operates in sealed mode and this
  type will raise if dump/load is attempted.
  """

  use Ecto.Type

  @prefix "v1:"

  def type, do: :string

  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_map(value) do
    key = encryption_key()
    json = Jason.encode!(value)
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, json, "", true)
    encoded = @prefix <> Base.encode64(iv <> tag <> ciphertext)
    {:ok, encoded}
  end

  def dump(_), do: :error

  def load(nil), do: {:ok, nil}

  def load(@prefix <> encoded) do
    key = encryption_key()

    with {:ok, decoded} <- Base.decode64(encoded),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- decoded,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false),
         {:ok, map} <- Jason.decode(plain, keys: :atoms) do
      {:ok, map}
    else
      _ -> {:error, :decryption_failed}
    end
  end

  def load(_), do: {:error, :decryption_failed}

  defp encryption_key do
    secret =
      Application.get_env(:gsmlg, :api_provider_encryption_key) ||
        raise "GSMLG :api_provider_encryption_key not configured. Set GSMLG_API_PROVIDER_KEY env var."

    :crypto.hash(:sha256, secret)
  end
end
