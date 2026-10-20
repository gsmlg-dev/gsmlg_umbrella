Code.require_file("lib/release/versions.ex", __DIR__)

root = Path.expand("..", __DIR__)

result =
  case System.argv() do
    ["--check"] -> GSMLG.Release.Versions.check(root)
    ["--check", version] -> GSMLG.Release.Versions.check(root, version)
    [version] -> GSMLG.Release.Versions.update(root, version)
    _ -> {:error, "Usage: scripts/update_version.sh VERSION | --check [VERSION]"}
  end

case result do
  :ok ->
    IO.puts("Updated root and application versions.")

  {:ok, version} ->
    IO.puts("Root and application versions match #{version}.")

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
