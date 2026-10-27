defmodule GSMLG.AdminWeb.GaoNoteMarkdown do
  @moduledoc false

  use Phoenix.Component

  alias GSMLG.GaoNote.Attachment
  alias PhoenixDuskmoon.Component.DataDisplay.Markdown

  @safe_link_schemes ~w(http https mailto tel)
  @safe_image_schemes ~w(http https)
  @normalization_passes 4
  @allowed_tags ~w(
    p br hr h1 h2 h3 h4 h5 h6 blockquote
    ul ol li pre code em strong del
    a img input
    table thead tbody tr th td
  )
  @allowed_attributes %{
    "a" => ~w(href title),
    "img" => ~w(src title alt),
    "input" => ~w(type checked disabled),
    "code" => ~w(class),
    "ol" => ~w(start),
    "th" => ~w(align),
    "td" => ~w(align)
  }

  @markdown_options [
    extension: [front_matter_delimiter: nil],
    render: [unsafe: false, github_pre_lang: false, full_info_string: false],
    sanitize: [
      tags: @allowed_tags,
      tag_attributes: @allowed_attributes,
      tag_attribute_values: %{"input" => %{"type" => ["checkbox"]}},
      generic_attributes: [],
      generic_attribute_prefixes: [],
      url_schemes: @safe_link_schemes,
      link_rel: nil
    ]
  ]

  attr :note, :map, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def body(assigns) do
    routes = attachment_routes(assigns.note.id, Map.get(assigns.note, :attachments, []))

    assigns =
      assign(assigns,
        source: assigns.note.content || "",
        plugins: [MDExGFM, {__MODULE__, routes: routes}],
        options: @markdown_options
      )

    ~H"""
    <Markdown.dm_markdown_body
      id={@id}
      class={@class}
      source={@source}
      plugins={@plugins}
      options={@options}
    />
    """
  end

  def attach(document, options) do
    routes = Keyword.fetch!(options, :routes)

    MDEx.Document.append_steps(document,
      gao_note_destinations: fn document ->
        MDEx.traverse_and_update(document, &sanitize_node(&1, routes))
      end
    )
  end

  def attachment_url(note_id, canonical_path)
      when is_binary(note_id) and is_binary(canonical_path) do
    with {:ok, ^canonical_path} <- Attachment.normalize_path(canonical_path),
         "./" <> relative_path <- canonical_path do
      encoded_path =
        relative_path
        |> String.split("/", trim: false)
        |> Enum.map_join(
          "/",
          &URI.encode(&1, fn character -> URI.char_unreserved?(character) end)
        )

      encoded_note_id =
        note_id
        |> to_string()
        |> URI.encode(fn character -> URI.char_unreserved?(character) end)

      "/gao_notes/notes/#{encoded_note_id}/attachments/#{encoded_path}"
    else
      _ -> nil
    end
  end

  def attachment_url(_note_id, _canonical_path), do: nil

  def reference(attachment) do
    destination = encode_destination(attachment.path)

    if String.starts_with?(attachment.mime, "image/") do
      label =
        case String.trim(attachment.description || "") do
          "" -> attachment.id
          description -> description
        end

      "![#{escape_label(label)}](#{destination})"
    else
      "[#{escape_label(Path.basename(attachment.path))}](#{destination})"
    end
  end

  defp attachment_routes(note_id, attachments) do
    Enum.reduce(attachments || [], %{}, fn attachment, routes ->
      path = Map.get(attachment, :path)

      case attachment_url(note_id, path) do
        nil -> routes
        url -> Map.put(routes, path, url)
      end
    end)
  end

  defp sanitize_node(%MDEx.Link{} = node, routes),
    do: sanitize_destination_node(node, :link, routes)

  defp sanitize_node(%MDEx.Image{} = node, routes),
    do: sanitize_destination_node(node, :image, routes)

  defp sanitize_node(node, _routes), do: node

  defp sanitize_destination_node(node, kind, routes) do
    url =
      case sanitize_destination(node.url, kind, routes) do
        {:ok, url} -> url
        # The final sanitizer removes this disallowed scheme, including its href/src attribute.
        :drop -> "about:invalid"
      end

    title = if safe_text_attribute?(node.title), do: node.title, else: ""
    %{node | url: url, title: title, attrs: nil}
  end

  defp sanitize_destination(destination, kind, routes) do
    case attachment_route(destination, routes) do
      :error ->
        :drop

      nil ->
        if safe_destination?(destination, kind), do: {:ok, destination}, else: :drop

      route ->
        {:ok, route}
    end
  end

  defp attachment_route(destination, routes) do
    Map.get(routes, destination) ||
      with {:ok, normalized} <- normalize_browser_references(destination) do
        Map.get(routes, normalized)
      end
  end

  defp safe_destination?(destination, kind) do
    with {:ok, normalized} <- normalize_browser_references(destination),
         false <- Regex.match?(~r/[\x00-\x20\x7f]/u, normalized) do
      case Regex.run(~r/\A([a-zA-Z][a-zA-Z0-9+.-]*):/, normalized) do
        nil -> true
        [_, scheme] -> String.downcase(scheme) in safe_schemes(kind)
      end
    else
      _invalid -> false
    end
  end

  defp normalize_browser_references(destination) do
    with true <- String.valid?(destination),
         false <- malformed_percent_encoding?(destination) do
      normalize_browser_references(destination, @normalization_passes)
    else
      _invalid -> :error
    end
  end

  defp normalize_browser_references(destination, 0) do
    case normalize_browser_reference_pass(destination) do
      {:ok, ^destination} -> {:ok, destination}
      _ambiguous -> :error
    end
  end

  defp normalize_browser_references(destination, remaining) do
    with {:ok, normalized} <- normalize_browser_reference_pass(destination) do
      if normalized == destination do
        {:ok, normalized}
      else
        normalize_browser_references(normalized, remaining - 1)
      end
    end
  end

  defp normalize_browser_reference_pass(destination) do
    destination = decode_percent_sequences(destination)

    with true <- String.valid?(destination),
         false <- ambiguous_named_reference?(destination),
         {:ok, destination} <- decode_numeric_references(destination) do
      {:ok, destination}
    else
      _invalid -> :error
    end
  end

  defp decode_percent_sequences(destination) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, destination, fn _, encoded ->
      <<String.to_integer(encoded, 16)>>
    end)
  end

  defp decode_numeric_references(destination) do
    with {:ok, destination} <-
           replace_numeric_references(destination, ~r/&#[xX]([0-9a-fA-F]+);?/, 16),
         {:ok, destination} <-
           replace_numeric_references(destination, ~r/&#([0-9]+);?/, 10),
         false <- String.contains?(destination, "&#"),
         true <- String.valid?(destination) do
      {:ok, destination}
    else
      _invalid -> :error
    end
  end

  defp replace_numeric_references(destination, pattern, base) do
    normalized =
      Regex.replace(pattern, destination, fn _, digits ->
        case Integer.parse(digits, base) do
          {codepoint, ""}
          when codepoint <= 0x10FFFF and codepoint not in 0xD800..0xDFFF ->
            <<codepoint::utf8>>

          _invalid ->
            throw(:invalid_character_reference)
        end
      end)

    {:ok, normalized}
  catch
    :invalid_character_reference -> :error
  end

  defp ambiguous_named_reference?(destination) do
    Regex.match?(~r/&[a-z][a-z0-9]+;/i, destination) or
      Regex.match?(~r/&(?:colon|tab|newline)(?=;|[^a-z0-9=]|$)/i, destination)
  end

  defp safe_text_attribute?(value) do
    String.valid?(value) and
      not Regex.match?(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/u, value)
  end

  defp malformed_percent_encoding?(destination),
    do: Regex.match?(~r/%(?![[:xdigit:]]{2})/, destination)

  defp safe_schemes(:link), do: @safe_link_schemes
  defp safe_schemes(:image), do: @safe_image_schemes

  defp escape_label(label) do
    label
    |> String.replace(~r/\R/u, " ")
    |> String.replace("\\", "\\\\")
    |> then(fn label ->
      Enum.reduce(["[", "]", "(", ")", "\""], label, fn character, escaped ->
        String.replace(escaped, character, "\\" <> character)
      end)
    end)
  end

  defp encode_destination(path) do
    URI.encode(path, fn character -> character == ?/ or URI.char_unreserved?(character) end)
  end
end
