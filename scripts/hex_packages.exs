Code.require_file("lib/release/hex_packages.ex", __DIR__)

try do
  case System.argv() do
    [command, _version, _output] when command in ["build", "publish"] ->
      raise "Hex packaging and publication for apps/ are suspended; release Docker images and application tarballs instead"

    _ ->
      raise ArgumentError,
            "Usage: elixir scripts/hex_packages.exs build|publish VERSION OUTPUT_DIRECTORY"
  end
rescue
  error ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
