{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
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
            "REPLACE_OS_VARS=true"
            "ERL_EPMD_PORT=4369"
            "ERLCOOKIE=96myjWoLCTZRko38UdngxxQo/SwP9vfga28/B6IL"
          ];
        };
      };
      commander_app = pkgs.callPackage ./pkgs/gsmlg_commander.nix {inherit system;};
    in {
      packages.umbrella_docker = umbrella_img;

      packages.umbrella_app = umbrella_app;
      packages.commander_app = commander_app;

      packages.default = umbrella_app;
    });
}
