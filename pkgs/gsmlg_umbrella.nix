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

  webNodeModules = buildNpmPackage {
    pname = "${pname}-gsmlg-web-npm-modules";
    inherit version;
    src = "${src}/apps/gsmlg_web";
    npmDepsHash = "sha256-xIIS/bTFpuJ2Pox0WAkZYt+pYtvkqsgc/p80TgYD4mI=";
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      cp -r node_modules "$out"
      runHook postInstall
    '';
  };
  adminWebNodeModules = buildNpmPackage {
    pname = "${pname}-gsmlg-admin-web-npm-modules";
    inherit version;
    src = "${src}apps/gsmlg_admin_web/";
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
      pkgs.bun
      pkgs.tailwindcss
    ];

    preBuild = ''
      cp ${pkgs.bun}/bin/bun _build/bun-linux-arm64
      cp ${pkgs.tailwindcss}/bin/tailwindcss _build/tailwind-linux-arm64
      cp -r ${webNodeModules} apps/gsmlg_web/assets/node_modules
      cd apps/gsmlg_web; mix assets.deploy; cd ../..
      cp -r ${adminWebNodeModules} apps/gsmlg_admin_web/assets/node_modules
      cd apps/gsmlg_admin_web; mix assets.deploy; cd ../..
    '';

    postBuild = ''
    '';

    meta = with lib; {
      description = "GSMLG UMBRELLA is the main program of GSMLG";
      mainProgram = "gsmlg_umbrella";
    };
  }
