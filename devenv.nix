{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "GSMLG Umbrella";

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    watchman
    tailwindcss_4
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam27Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  # PostgreSQL database service
  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_16;
    listen_addresses = "";  # Empty string = Unix socket only
    initialDatabases = [
      { name = "gsmlg_dev"; }
      { name = "gsmlg_test"; }
    ];
    initialScript = ''
      CREATE USER gsmlg_dev WITH PASSWORD 'gsmlg_dev' CREATEDB;
      GRANT ALL PRIVILEGES ON DATABASE gsmlg_dev TO gsmlg_dev;
      GRANT ALL PRIVILEGES ON DATABASE gsmlg_test TO gsmlg_dev;
      ALTER DATABASE gsmlg_dev OWNER TO gsmlg_dev;
      ALTER DATABASE gsmlg_test OWNER TO gsmlg_dev;
    '';
  };

  # Set DATABASE_URL for Ecto to use Unix socket
  env.DATABASE_URL = "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev?socket=${config.env.DEVENV_STATE}/postgres";
  env.PGHOST = "${config.env.DEVENV_STATE}/postgres";
  env.PGUSER = "gsmlg_dev";
  env.PGDATABASE = "gsmlg_dev";

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
