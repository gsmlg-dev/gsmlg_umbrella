Code.require_file("versions.ex", __DIR__)

defmodule GSMLG.Release.HexPackages do
  @moduledoc "Builds opted-in umbrella packages and publishes a verified release set."

  def discover!(root, version) do
    case GSMLG.Release.Versions.check(root, version) do
      {:ok, ^version} -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    Mix.start()
    Mix.env(:prod)

    files = root |> Path.join("apps/*/mix.exs") |> Path.wildcard()
    internal_apps = MapSet.new(files, &Path.basename(Path.dirname(&1)))

    packages =
      files
      |> Enum.flat_map(fn file ->
        path = Path.dirname(file)
        app = path |> Path.basename() |> String.to_atom()

        Mix.Project.in_project(app, path, fn _ ->
          config = Mix.Project.config()

          if Keyword.has_key?(config, :package),
            do: [package!(config, path, version, internal_apps)],
            else: []
        end)
      end)

    if packages == [], do: raise(ArgumentError, "no projects declare Hex package metadata")

    if Enum.uniq_by(packages, & &1.name) != packages,
      do: raise(ArgumentError, "duplicate Hex package names")

    order!(packages)
  end

  def order!(packages) do
    apps = Enum.map(packages, & &1.app)

    for package <- packages, dependency <- package.deps, dependency not in apps do
      raise ArgumentError,
            "#{package.app}: internal dependency #{dependency} is not enabled for Hex"
    end

    sort!(Enum.sort_by(packages, & &1.app), [])
  end

  def build!(packages, version, output, run \\ &System.cmd/3) do
    File.mkdir_p!(output)
    File.rm(Path.join(output, "manifest.json"))

    entries =
      Enum.map(packages, fn package ->
        archive = "#{package.name}-#{version}.tar"
        file = Path.join(output, archive)
        command!(run, "mix", ["hex.build", "--output", file], package.path)
        Map.merge(identity(package), %{"archive" => archive, "sha256" => checksum(file)})
      end)

    File.write!(
      Path.join(output, "manifest.json"),
      JSON.encode!(%{version: version, packages: entries})
    )

    IO.puts("Built #{length(entries)} Hex packages at #{version}.")
  end

  def publish!(packages, version, output, run \\ &System.cmd/3) do
    if System.get_env("HEX_API_KEY") in [nil, ""], do: raise("HEX_API_KEY is required")
    manifest = output |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

    unless manifest["version"] == version and
             Enum.map(manifest["packages"], &Map.take(&1, ["app", "name", "version", "deps"])) ==
               Enum.map(packages, &identity/1) do
      raise "Hex manifest does not match the requested release set"
    end

    entries = Enum.zip(packages, manifest["packages"])

    # Validate the entire release set before contacting Hex or publishing anything.
    Enum.each(entries, fn {_package, entry} ->
      unless entry["archive"] == "#{entry["name"]}-#{version}.tar" and
               checksum(Path.join(output, entry["archive"])) == entry["sha256"] do
        raise "candidate archive checksum mismatch for #{entry["name"]}"
      end
    end)

    Enum.each(entries, fn {package, entry} ->
      verification = Path.join(output, "verify-#{entry["archive"]}")

      try do
        command!(run, "mix", ["hex.build", "--output", verification], package.path)

        unless checksum(verification) == entry["sha256"],
          do: raise("source builds a different archive for #{package.name}")
      after
        File.rm(verification)
      end
    end)

    pending =
      Enum.filter(entries, fn {_package, entry} ->
        expected = entry["sha256"]

        case remote_checksum!(entry, output, run) do
          nil -> true
          ^expected -> false
          _ -> raise "#{entry["name"]} #{version} already exists with a different archive"
        end
      end)

    Enum.each(pending, fn {package, entry} ->
      IO.puts("Publishing #{package.name} #{version}...")
      command!(run, "mix", ["hex.publish", "package", "--yes"], package.path)

      unless published_checksum!(entry, output, run, 6) == entry["sha256"],
        do: raise("published archive checksum mismatch for #{package.name}")
    end)

    IO.puts(
      "Verified #{length(entries)} Hex packages at #{version} (#{length(pending)} newly published)."
    )
  end

  defp package!(config, path, version, internal_apps) do
    app = Atom.to_string(config[:app])
    metadata = config[:package]
    name = to_string(metadata[:name] || app)

    unless Regex.match?(~r/^[a-z][a-z0-9_]*$/, name),
      do: raise(ArgumentError, "#{app}: invalid Hex package name")

    unless is_binary(config[:description]) and config[:description] != "" and
             metadata[:licenses] not in [nil, []] and metadata[:files] not in [nil, []] do
      raise ArgumentError, "#{app}: description, licenses and package files are required"
    end

    for pattern <- metadata[:files],
        Path.wildcard(Path.join(path, pattern), match_dot: true) == [] do
      raise ArgumentError, "#{app}: package file #{pattern} does not exist"
    end

    dependencies =
      (config[:deps] || [])
      |> Enum.flat_map(fn dependency ->
        {dependency_app, requirement, options} =
          case dependency do
            {dep, requirement, options} -> {dep, requirement, options}
            {dep, options} when is_list(options) -> {dep, nil, options}
            {dep, requirement} -> {dep, requirement, []}
          end

        if :prod in List.wrap(options[:only] || [:prod]) do
          cond do
            options[:path] || options[:git] || options[:github] ->
              raise ArgumentError, "#{app}: #{dependency_app} is not a Hex dependency"

            options[:in_umbrella] || MapSet.member?(internal_apps, Atom.to_string(dependency_app)) ->
              unless requirement == version do
                raise ArgumentError,
                      "#{app}: #{dependency_app} must require exact release version #{version}"
              end

              [Atom.to_string(dependency_app)]

            true ->
              unless is_binary(requirement) and
                       match?({:ok, _}, Version.parse_requirement(requirement)) do
                raise ArgumentError,
                      "#{app}: #{dependency_app} has an invalid Hex version requirement"
              end

              []
          end
        else
          []
        end
      end)

    %{app: app, name: name, version: version, path: path, deps: Enum.sort(dependencies)}
  end

  defp sort!([], ordered), do: ordered

  defp sort!(remaining, ordered) do
    done = Enum.map(ordered, & &1.app)

    {ready, waiting} =
      Enum.split_with(remaining, fn package -> Enum.all?(package.deps, &(&1 in done)) end)

    if ready == [], do: raise(ArgumentError, "internal Hex dependency cycle")
    sort!(waiting, ordered ++ ready)
  end

  defp identity(package) do
    %{
      "app" => package.app,
      "name" => package.name,
      "version" => package.version,
      "deps" => package.deps
    }
  end

  defp checksum(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp command!(run, command, args, directory) do
    {output, status} =
      run.(command, args,
        cd: directory,
        env: [{"MIX_ENV", "prod"}, {"GSMLG_HEX_BUILD", "1"}]
      )

    if output != "", do: IO.write(output)
    if status != 0, do: raise("#{command} failed (#{status}): #{output}")
    output
  end

  defp remote_checksum!(entry, output, run) do
    file = Path.join(output, "remote-#{entry["archive"]}")
    url = "https://repo.hex.pm/tarballs/#{entry["archive"]}"

    try do
      {status, exit_code} =
        run.(
          "curl",
          [
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            "10",
            "--max-time",
            "60",
            "--retry",
            "3",
            "--retry-delay",
            "1",
            "--output",
            file,
            "--write-out",
            "%{http_code}",
            url
          ],
          []
        )

      if exit_code != 0, do: raise("failed to fetch #{url}: #{status}")

      case String.trim(status) do
        "200" -> checksum(file)
        "404" -> nil
        code -> raise "Hex archive request failed with HTTP #{code}: #{url}"
      end
    after
      File.rm(file)
    end
  end

  defp published_checksum!(entry, output, run, attempts) do
    case remote_checksum!(entry, output, run) do
      nil when attempts > 1 ->
        Process.sleep(1_000)
        published_checksum!(entry, output, run, attempts - 1)

      nil ->
        raise "published archive is not available for #{entry["name"]}"

      checksum ->
        checksum
    end
  end
end
