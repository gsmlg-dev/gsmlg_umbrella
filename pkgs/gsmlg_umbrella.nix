{
  lib,
  pkgs,
  buildNpmPackage,
  beamPackages,
  nodejs,
  ...
}: let
  pname = "gsmlg_umbrella";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../.;
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    # nix will complain and tell you the right value to replace this with
    hash = "sha256-CIceAuuNZFlUCHywj4N3pFvQpGT8SqjfT7IftUfhz2o=";
    mixEnv = "prod"; # default is "prod", when empty includes all dependencies, such as "dev", "test".
    # if you have build time environment variables add them here
    RELEASE_COOKIE = "1mhgcvb78q9wzbls5a3wgczmm89xp5d9";
  };

  nodeModules = buildNpmPackage {
    pname = "${pname}-npm-modules";
    inherit version;
    src = "${src}";
    npmDepsHash = "sha256-xIIS/bTFpuJ2Pox0WAkZYt+pYtvkqsgc/p80TgYD4mI=";
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      cp -r node_modules "$out"
      runHook postInstall
    '';
  };
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps;

    nativeBuildInputs = [
      nodejs
      pkgs.esbuild
      pkgs.tailwindcss
    ];

    preBuild = ''
      cp -r ${nodeModules} node_modules
      cp ${pkgs.esbuild}/bin/esbuild _build/esbuild-linux-arm64
      cp ${pkgs.tailwindcss}/bin/tailwindcss _build/tailwind-linux-arm64
      mix assets.deploy
    '';

    postBuild = ''
    '';

    meta = with lib; {
      description = "GSMLG UMBRELLA is the main program of GSMLG";
      mainProgram = "gsmlg_umbrella";
    };
  }
