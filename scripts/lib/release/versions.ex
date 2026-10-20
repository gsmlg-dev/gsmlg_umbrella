defmodule GSMLG.Release.Versions do
  @moduledoc "Checks and stamps standalone version declarations across an umbrella."

  def check(root, expected_version \\ nil) do
    safely(fn ->
      if expected_version, do: validate_version!(expected_version)
      projects = read_projects!(root)
      expected_version = expected_version || hd(projects).version

      mismatches =
        for project <- projects, project.version != expected_version do
          "#{project.path}: version #{project.version}, expected #{expected_version}"
        end

      if mismatches == [],
        do: {:ok, expected_version},
        else: {:error, Enum.join(mismatches, "\n")}
    end)
  end

  def update(root, version) do
    safely(fn ->
      validate_version!(version)
      projects = read_projects!(root)

      # Read and validate every declaration before changing any source file.
      Enum.each(projects, fn project ->
        <<before::binary-size(project.offset), rest::binary>> = project.source

        rest =
          binary_part(
            rest,
            byte_size(project.literal),
            byte_size(rest) - byte_size(project.literal)
          )

        updated = before <> inspect(version) <> rest
        if updated != project.source, do: File.write!(project.file, updated)
      end)

      :ok
    end)
  end

  defp read_projects!(root) do
    root = Path.expand(root)
    read_mix_projects!(root) ++ read_json_projects!(root)
  end

  defp read_mix_projects!(root) do
    files = [Path.join(root, "mix.exs") | Path.wildcard(Path.join(root, "apps/*/mix.exs"))]

    Enum.map(files, fn file ->
      path = Path.relative_to(file, root)
      source = File.read!(file)

      ast =
        Code.string_to_quoted!(source,
          file: path,
          columns: true,
          token_metadata: true,
          literal_encoder: fn
            value, metadata when is_binary(value) ->
              {:ok, {:version_string, metadata, [value]}}

            value, _metadata ->
              {:ok, value}
          end
        )

      {_, {versions, attributes}} =
        Macro.prewalk(ast, {[], []}, fn
          {:version, value} = node, {versions, attributes} ->
            {node, {[value | versions], attributes}}

          {:@, _, [{:version, _, [value]}]} = node, {versions, attributes} ->
            {node, {versions, [value | attributes]}}

          node, accumulator ->
            {node, accumulator}
        end)

      declaration =
        case {versions, attributes} do
          {[{:version_string, _, [_]} = literal], []} ->
            literal

          {[{:@, _, [{:version, _, nil}]}], [literal]} ->
            literal

          _ ->
            raise ArgumentError,
                  "#{path}: expected one literal version or one @version declaration"
        end

      case declaration do
        {:version_string, metadata, [version]} ->
          validate_version!(version, path)

          unless metadata[:delimiter] == "\"" do
            raise ArgumentError, "#{path}: version must use a double-quoted string literal"
          end

          lines = String.split(source, "\n")
          prefix = Enum.take(lines, metadata[:line] - 1)
          line = Enum.at(lines, metadata[:line] - 1)

          column_prefix = String.slice(line, 0, metadata[:column] - 1)

          before = Enum.join(prefix ++ [column_prefix], "\n")
          literal = inspect(version)

          unless binary_part(source, byte_size(before), byte_size(literal)) == literal do
            raise ArgumentError, "#{path}: version must be an unescaped literal"
          end

          %{
            file: file,
            path: path,
            source: source,
            version: version,
            offset: byte_size(before),
            literal: literal
          }

        _ ->
          raise ArgumentError, "#{path}: @version must be a string literal"
      end
    end)
  end

  defp read_json_projects!(root) do
    files =
      Path.wildcard(Path.join(root, "package.json")) ++
        Path.wildcard(Path.join(root, "apps/*/package.json"))

    Enum.flat_map(files, fn file ->
      path = Path.relative_to(file, root)
      source = File.read!(file)

      manifest =
        case JSON.decode(source) do
          {:ok, manifest} when is_map(manifest) -> manifest
          {:ok, _} -> raise ArgumentError, "#{path}: expected a JSON object"
          {:error, error} -> raise ArgumentError, "#{path}: invalid JSON #{inspect(error)}"
        end

      case Map.fetch(manifest, "version") do
        :error ->
          []

        {:ok, version} ->
          validate_version!(version, path)

          # Token offsets let us change only the top-level value and preserve JSON formatting.
          tokens =
            Regex.scan(~r/"(?:[^"\\]|\\.)*"|[{}\[\]:,]/, source, return: :index)
            |> Enum.map(fn [{offset, length}] ->
              {binary_part(source, offset, length), offset}
            end)

          case json_version_tokens(tokens, 0, []) do
            [{literal, offset}] ->
              [
                %{
                  file: file,
                  path: path,
                  source: source,
                  version: version,
                  offset: offset,
                  literal: literal
                }
              ]

            _ ->
              raise ArgumentError, "#{path}: expected one top-level version declaration"
          end
      end
    end)
  end

  defp json_version_tokens([], _depth, versions), do: versions

  defp json_version_tokens([{key, _}, {":", _}, value | rest], 1, versions) do
    versions = if JSON.decode!(key) == "version", do: [value | versions], else: versions
    json_version_tokens([value | rest], 1, versions)
  end

  defp json_version_tokens([{token, _} | rest], depth, versions) do
    depth =
      case token do
        opening when opening in ["{", "["] -> depth + 1
        closing when closing in ["}", "]"] -> depth - 1
        _ -> depth
      end

    json_version_tokens(rest, depth, versions)
  end

  defp validate_version!(version, path \\ nil) do
    unless is_binary(version) and match?({:ok, _}, Version.parse(version)) do
      prefix = if path, do: "#{path}: ", else: ""
      raise ArgumentError, "#{prefix}invalid semantic version #{inspect(version)}"
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error in [ArgumentError, File.Error, SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, Exception.message(error)}
  end
end
