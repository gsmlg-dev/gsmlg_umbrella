defmodule GSMLG.Browser.ArtifactPolicy do
  @moduledoc false

  alias GSMLG.Commander.Protocol.ArtifactManifest

  def validate_type(kind, mime, filename) do
    case ArtifactManifest.validate_media(kind, mime, filename) do
      :ok -> :ok
      {:error, _protocol_error} -> {:error, :invalid_artifact_type}
    end
  end

  def verify_content(%{size: size, sha256: sha256}, content) when is_binary(content) do
    actual = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    if byte_size(content) == size and Plug.Crypto.secure_compare(actual, sha256),
      do: :ok,
      else: {:error, :artifact_integrity_failed}
  end
end
