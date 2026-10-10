#!/usr/bin/env bash
# Run inside the project's devenv shell. Use a clean package consumer, not the umbrella lockfile.
set -euo pipefail
app_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/gsmlg-whois-ets-consumer.XXXXXX")
trap 'rm -rf -- "$consumer_root"' EXIT

cd "$app_root"
mix hex.build --output "$consumer_root/package.tar"
mkdir -p "$consumer_root/archive" "$consumer_root/deps/gsmlg_whois" "$consumer_root/config"
tar -xf "$consumer_root/package.tar" -C "$consumer_root/archive"
tar -xzf "$consumer_root/archive/contents.tar.gz" -C "$consumer_root/deps/gsmlg_whois"
cat > "$consumer_root/mix.exs" <<'ELIXIR'
defmodule WhoisConsumer.MixProject do
  use Mix.Project
  def project do
    [app: :whois_consumer, version: "0.1.0", elixir: "~> 1.18",
     deps: [{:gsmlg_whois, path: "deps/gsmlg_whois"}]]
  end
  def application, do: [extra_applications: [:logger]]
end
ELIXIR
printf 'import Config\n' > "$consumer_root/config/config.exs"
cat > "$consumer_root/audit_deps.exs" <<'ELIXIR'
deps = Mix.Dep.Lock.read() |> Map.keys() |> Enum.sort()
IO.inspect(deps, label: "ETS-only resolved dependencies")
for app <- [:concord, :ex_turso, :ra, :libcluster, :postgrex] do
  if app in deps, do: raise("Unexpected ETS-only dependency: #{app}")
end
ELIXIR
cat > "$consumer_root/smoke.exs" <<'ELIXIR'
{:ok, _started} = Application.ensure_all_started(:whois_consumer)
apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
IO.inspect(apps, label: "ETS-only started applications")
for app <- [:gsmlg_whois, :http_fetch, :telemetry] do
  if app not in apps, do: raise("Missing required ETS-only application: #{app}")
end
for app <- [:concord, :ex_turso, :ra, :libcluster, :postgrex] do
  if app in apps, do: raise("Unexpected ETS-only runtime: #{app}")
end
GSMLG.Whois.Cache.ETS = GSMLG.Whois.Cache.impl()
{:ok, _pid} = GSMLG.Whois.Cache.ETS.start_link([])
:ok = GSMLG.Whois.Cache.put("consumer.test", [{"whois.test", "cached record"}], :domain)
{:ok, [{"whois.test", "cached record"}]} = GSMLG.Whois.Cache.get("consumer.test")
:ok = GSMLG.Whois.Cache.delete("consumer.test")
:miss = GSMLG.Whois.Cache.get("consumer.test")
:ok = GSMLG.Whois.Cache.clear()
IO.puts("ETS cache round trip passed")
ELIXIR

cd "$consumer_root"
export MIX_ENV=prod
mix deps.get
mix run --no-compile --no-deps-check --no-start audit_deps.exs
mix compile --warnings-as-errors
mix run smoke.exs
mix release
for app in concord ex_turso ra libcluster postgrex; do
  if compgen -G "_build/prod/rel/whois_consumer/lib/$app-*" >/dev/null; then
    printf 'Unexpected ETS-only release application: %s\n' "$app" >&2
    exit 1
  fi
done
_build/prod/rel/whois_consumer/bin/whois_consumer eval "Code.eval_file(\"$consumer_root/smoke.exs\")"
printf 'Clean Hex package consumer dependency, compile, runtime, release, and ETS checks passed\n'
