defmodule GSMLG.Component.Markdown do
  @moduledoc """
  Server-rendered Markdown shared by the public blog and admin preview.
  """

  use Phoenix.Component

  alias PhoenixDuskmoon.Component.DataDisplay.Markdown

  @sanitize_options MDEx.Document.default_sanitize_options()
                    |> Keyword.update!(:tags, &["input" | &1])
                    |> Keyword.update!(
                      :tag_attributes,
                      &Map.put(&1, "input", ~w(type checked disabled))
                    )
                    |> Keyword.put(:tag_attribute_values, %{"input" => %{"type" => ["checkbox"]}})

  attr(:data, :string, default: nil)

  def markdown(assigns) do
    assigns =
      assign(assigns,
        source: assigns.data || "",
        options: [
          extension: [front_matter_delimiter: nil],
          render: [unsafe: false, hardbreaks: false, github_pre_lang: false],
          sanitize: @sanitize_options
        ]
      )

    ~H"""
    <Markdown.dm_markdown_body
      class="px-4"
      source={@source}
      plugins={[MDExGFM]}
      options={@options}
    />
    """
  end
end
