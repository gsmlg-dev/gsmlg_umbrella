defmodule GSMLG.AdminWeb.GaoNoteMarkdown do
  @moduledoc false

  alias GSMLG.GaoNote.Attachment

  @safe_link_schemes ~w(http https mailto tel)
  @safe_image_schemes ~w(http https)
  @normalization_passes 4
  @allowed_tags ~w(
    p br hr h1 h2 h3 h4 h5 h6 blockquote
    ul ol li pre code em strong del
    a img
    table thead tbody tr th td
  )
  @allowed_attributes %{
    "a" => ~w(href title),
    "img" => ~w(src title),
    "code" => ~w(class),
    "ol" => ~w(start),
    "th" => ~w(align),
    "td" => ~w(align)
  }

  def render(%{id: note_id, content: content} = note) do
    routes = attachment_routes(note_id, Map.get(note, :attachments, []))
    {_, ast, _messages} = Earmark.Parser.as_ast(content || "", escape: true)

    ast = sanitize_nodes(ast, routes)

    # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#70
    ast
    |> Earmark.transform(escape: true)
    |> Phoenix.HTML.raw()
  end

  def attachment_url(note_id, canonical_path)
      when is_binary(note_id) and is_binary(canonical_path) do
    with {:ok, ^canonical_path} <- Attachment.normalize_path(canonical_path),
         "./" <> relative_path <- canonical_path do
      encoded_path =
        relative_path
        |> String.split("/", trim: false)
        |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))

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

  defp sanitize_nodes(nodes, routes) when is_list(nodes) do
    Enum.flat_map(nodes, &sanitize_node(&1, routes))
  end

  defp sanitize_nodes(node, routes), do: sanitize_node(node, routes)

  defp sanitize_node(text, _routes) when is_binary(text), do: [text]
  defp sanitize_node({:comment, _attributes, _children, _meta}, _routes), do: []

  defp sanitize_node({tag, attributes, children, meta}, routes) when is_binary(tag) do
    tag = String.downcase(tag)

    cond do
      verbatim?(meta) and tag != "code" ->
        []

      tag in @allowed_tags ->
        safe_children = sanitize_nodes(children, routes)

        safe_attributes =
          tag
          |> sanitize_attributes(attributes, routes)
          |> put_image_alt(tag, safe_children, attributes)

        [
          {
            tag,
            safe_attributes,
            safe_children,
            %{}
          }
        ]

      true ->
        []
    end
  end

  defp sanitize_node(_unknown, _routes), do: []

  defp sanitize_attributes(tag, attributes, routes) do
    allowed = Map.get(@allowed_attributes, tag, [])

    attributes
    |> Enum.reduce([], fn
      {name, value}, sanitized when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if name in allowed and not List.keymember?(sanitized, name, 0) do
          case sanitize_attribute(tag, name, value, routes) do
            {:ok, value} -> [{name, escape_attribute(value)} | sanitized]
            :drop -> sanitized
          end
        else
          sanitized
        end

      _attribute, sanitized ->
        sanitized
    end)
    |> Enum.reverse()
  end

  defp put_image_alt(attributes, "img", children, parser_attributes) do
    alt =
      case safe_child_text(children) do
        "" -> parser_image_alt(parser_attributes)
        child_text -> {:ok, child_text}
      end

    case alt do
      {:ok, alt} ->
        alt =
          alt
          |> String.replace("\r\n", "\n")
          |> String.replace("\r", "\n")

        if safe_text_attribute?(alt) do
          [{"alt", escape_attribute(alt)} | attributes]
        else
          attributes
        end

      :error ->
        attributes
    end
  end

  defp put_image_alt(attributes, _tag, _children, _parser_attributes), do: attributes

  defp parser_image_alt([{"src", source}, {"alt", alt} | _rest])
       when is_binary(source) and is_binary(alt) do
    decode_parser_alt(alt)
  end

  defp parser_image_alt(_attributes), do: :error

  defp decode_parser_alt(alt) do
    normalized =
      Regex.replace(
        ~r/&(?:amp|quot|apos|lt|gt|#[0-9]+|#[xX][0-9a-fA-F]+);/,
        alt,
        &decode_parser_alt_entity/1
      )

    if String.valid?(normalized), do: {:ok, normalized}, else: :error
  catch
    :invalid_parser_alt_entity -> :error
  end

  defp decode_parser_alt_entity("&amp;"), do: "&"
  defp decode_parser_alt_entity("&quot;"), do: "\""
  defp decode_parser_alt_entity("&apos;"), do: "'"
  defp decode_parser_alt_entity("&lt;"), do: "<"
  defp decode_parser_alt_entity("&gt;"), do: ">"

  defp decode_parser_alt_entity("&#x" <> encoded),
    do: decode_parser_alt_codepoint(encoded, 16)

  defp decode_parser_alt_entity("&#X" <> encoded),
    do: decode_parser_alt_codepoint(encoded, 16)

  defp decode_parser_alt_entity("&#" <> encoded),
    do: decode_parser_alt_codepoint(encoded, 10)

  defp decode_parser_alt_codepoint(encoded, base) do
    encoded = String.trim_trailing(encoded, ";")

    case Integer.parse(encoded, base) do
      {codepoint, ""}
      when codepoint <= 0x10FFFF and not (codepoint in 0xD800..0xDFFF) ->
        <<codepoint::utf8>>

      _invalid ->
        throw(:invalid_parser_alt_entity)
    end
  end

  defp safe_child_text(nodes) when is_list(nodes),
    do: Enum.map_join(nodes, "", &safe_child_text/1)

  defp safe_child_text(node) when is_binary(node), do: node
  defp safe_child_text({_tag, _attributes, children, _meta}), do: safe_child_text(children)
  defp safe_child_text(_node), do: ""

  defp escape_attribute(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp sanitize_attribute("a", "href", destination, routes),
    do: sanitize_destination(destination, :link, routes)

  defp sanitize_attribute("img", "src", destination, routes),
    do: sanitize_destination(destination, :image, routes)

  defp sanitize_attribute("code", "class", class, _routes) do
    if Regex.match?(~r/\A(?:language-)?[a-zA-Z0-9_+-]+\z/, class),
      do: {:ok, class},
      else: :drop
  end

  defp sanitize_attribute("ol", "start", start, _routes) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, start), do: {:ok, start}, else: :drop
  end

  defp sanitize_attribute(tag, "align", align, _routes) when tag in ["th", "td"] do
    if align in ["left", "center", "right"], do: {:ok, align}, else: :drop
  end

  defp sanitize_attribute(_tag, name, value, _routes) when name in ["title", "alt"] do
    if safe_text_attribute?(value), do: {:ok, value}, else: :drop
  end

  defp sanitize_attribute(_tag, _name, _value, _routes), do: :drop

  defp sanitize_destination(destination, kind, routes) do
    case attachment_route(destination, routes) do
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
          when codepoint <= 0x10FFFF and not (codepoint in 0xD800..0xDFFF) ->
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

  defp verbatim?(meta) when is_map(meta), do: Map.get(meta, :verbatim, false) == true
  defp verbatim?(_meta), do: false

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
