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
      commander_app = pkgs.callPackage ./pkgs/gsmlg_commander.nix {inherit system;};
    in {
      packages.gsmlg-umbrella = umbrella_app;
      packages.gsmlg-commander = commander_app;

      packages.default = umbrella_app;
    });
}
