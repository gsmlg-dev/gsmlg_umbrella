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
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  # PostgreSQL database service
  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_16;
    listen_addresses = "";  # Empty string = Unix socket only
    initialScript = ''
      CREATE USER gsmlg_dev WITH PASSWORD 'gsmlg_dev' CREATEDB;
      CREATE DATABASE gsmlg_dev OWNER gsmlg_dev;
      CREATE DATABASE gsmlg_test OWNER gsmlg_dev;
    '';
  };

  # DATABASE_URL for Ecto (socket_dir is handled separately via PGHOST)
  env.DATABASE_URL = "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev";
  env.PGHOST = "${config.env.DEVENV_ROOT}/.devenv/run/postgres";

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  scripts.db-setup.exec = ''
    echo "Setting up database..."
    mix ecto.create
    mix ecto.migrate
    echo "Database setup complete!"
  '';

  enterShell = ''
    hello
    echo "PostgreSQL socket: $PGHOST"
  '';

}
