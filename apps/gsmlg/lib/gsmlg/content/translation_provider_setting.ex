defmodule GSMLG.Content.TranslationProviderSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @default_system_prompt """
  You are a professional translator. Translate the following blog post from {source} to {target}.
  Preserve all Markdown formatting exactly as-is.
  Return ONLY a JSON object with exactly two keys: "title" and "content".
  Do not include any explanation or text outside the JSON object.
  """

  schema "translation_provider_settings" do
    field :provider, :string, default: "claude"
    field :api_key, :string, default: ""
    field :model, :string, default: "claude-haiku-4-5-20251001"
    field :system_prompt, :string

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:provider, :api_key, :model, :system_prompt])
    |> validate_required([:provider, :model])
    |> validate_inclusion(:provider, ["claude"])
  end

  def default_system_prompt, do: String.trim(@default_system_prompt)
end
