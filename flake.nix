{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      umbrella_app = pkgs.callPackage ./pkgs/gsmlg_umbrella.nix {inherit system;};
      umbrella_img = pkgs.dockerTools.buildImage {
        name = "ghcr.io/gsmlg-dev/gsmlg-umbrella";
        tag = "latest";
        created = "now";
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          paths = [
            pkgs.busybox
            pkgs.dockerTools.usrBinEnv
            pkgs.dockerTools.binSh
            pkgs.dockerTools.caCertificates
            pkgs.dockerTools.fakeNss
            umbrella_app
          ];
          pathsToLink = ["/bin" "/etc" "/var"];
        };

        config = {
          Entrypoint = ["/bin/gsmlg_umbrella"];
          Cmd = ["start"];
          Env = [
            "PORT=4110"
            "ADMIN_PORT=4111"
            "PHX_HOST=gsmlg.org"
            "REPLACE_OS_VARS=true"
            "ERL_EPMD_PORT=4369"
            "ERLCOOKIE=96myjWoLCTZRko38UdngxxQo/SwP9vfga28/B6IL"
            "POOL_SIZE=10"
            "PHX_SERVER=true"
            "RELEASE_COOKIE=3swYaASXT0ARmMHUjiDsesfoe9n=./SMQbQx6kX4+Z6+9S9YA2lS6lVNdQiX93Wv"
            "SECRET_KEY_BASE=e1NY0tzLDkFHVlckQomf/J9RcV+lfxSrgSoxxs0LNSR8g;sY)$NwqUiGagasIkBD"
          ];
        };
      };
      commander_app = pkgs.callPackage ./pkgs/gsmlg_commander.nix {inherit system;};
    in {
      packages.umbrella_docker = umbrella_img;

      packages.umbrella_app = umbrella_app;
      packages.commander_app = commander_app;

      packages.default = umbrella_app;

      devShells.default = pkgs.mkShell {
        name = "GSMLG UMBRELLA Dev Shell";

        buildInputs = [
          pkgs.figlet
          pkgs.dart

          pkgs.elixir
          pkgs.bun
          pkgs.tailwindcss

          pkgs.nodejs_20

          pkgs.nodePackages.pnpm

          pkgs.zig
          pkgs.p7zip
        ];

        shellHook = ''
          figlet -w 120 -f starwars GSMLG UMBRELLA
          figlet -w 120 -f starwars Dev Shell
          export PATH="$PATH":"$HOME/.pub-cache/bin"
          export EDITOR=vim
        '';
      };
    });
}
