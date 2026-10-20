Code.require_file("lib/release/hex_packages.ex", __DIR__)

try do
  case System.argv() do
    [command, version, output] when command in ["build", "publish"] ->
      root = Path.expand("..", __DIR__)
      packages = GSMLG.Release.HexPackages.discover!(root, version)
      output = Path.expand(output)

      case command do
        "build" -> GSMLG.Release.HexPackages.build!(packages, version, output)
        "publish" -> GSMLG.Release.HexPackages.publish!(packages, version, output)
      end

    _ ->
      raise ArgumentError,
            "Usage: elixir scripts/hex_packages.exs build|publish VERSION OUTPUT_DIRECTORY"
  end
rescue
  error ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
