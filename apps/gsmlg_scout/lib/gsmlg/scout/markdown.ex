defmodule GSMLG.Scout.Markdown do
  @moduledoc false

  def title(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.trim(line) do
        "# " <> title -> String.trim(title)
        _ -> nil
      end
    end)
  end

  def title(_markdown), do: nil

  def word_count(markdown) when is_binary(markdown) do
    ~r/[\p{L}\p{N}_'-]+/u
    |> Regex.scan(markdown)
    |> length()
  end

  def word_count(_markdown), do: 0
end
