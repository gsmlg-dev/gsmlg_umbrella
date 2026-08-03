{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "GSMLG Umbrella";
  env.MIX_BUN_PATH = lib.getExe pkgs-stable.bun;
  env.MIX_TAILWIND_PATH = lib.getExe pkgs-stable.tailwindcss_4;
  env.NODE_PATH = "${config.git.root}/deps";

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    watchman
    tailwindcss_4
    beam28Packages.elixir-ls
    vips          # libvips for image processing (gsmlg_storage)
    pkg-config    # needed by Vix NIF to find libvips
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  env.AWS_ACCESS_KEY_ID = "minioadmin";
  env.AWS_SECRET_ACCESS_KEY = "minioadmin";
  env.AWS_ENDPOINT_URL = "http://localhost:9000";
  env.AWS_REGION = "us-east-1";

  processes.gsmlg-umbrella = {
    exec = "dev-server";
    after = [ "devenv:processes:postgres" ];
  };

  # PostgreSQL database service
  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_16;
    listen_addresses = "";  # Empty string = Unix socket only
    port = 5433;
    initialScript = ''
      CREATE USER gsmlg_dev WITH PASSWORD 'gsmlg_dev' CREATEDB;
      CREATE DATABASE gsmlg_dev OWNER gsmlg_dev;
      CREATE DATABASE gsmlg_test OWNER gsmlg_dev;
    '';
  };

  # DATABASE_URL for Ecto. services.postgres exports PGHOST/PGPORT for its
  # runtime socket; dev config falls back to this URL when that socket is absent.
  env.DATABASE_URL = "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev";

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  scripts.db-setup.exec = ''
    echo "Setting up database..."
    mix ecto.create
    mix ecto.migrate
    echo "Database setup complete!"
  '';

  scripts.dev-server.exec = ''
    set -euo pipefail
    proxy_rules_state=.devenv/state/proxy-rules
    mkdir -p -- "$proxy_rules_state/sources/proxy" \
      "$proxy_rules_state/sources/direct"
    mix ecto.create --quiet
    mix ecto.migrate
    exec mix service.run
  '';

  enterShell = ''
    hello
    echo "PostgreSQL socket: $PGHOST:$PGPORT"
  '';

}
