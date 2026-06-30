{
  lib,
  beamPackages,
  ...
}: let
  pname = "gsmlg_scout_agent";
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
    RELEASE_COOKIE = "m5m8r9wgc6qhv4awqvqg";
  };
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps;

    nativeBuildInputs = [
    ];

    preBuild = ''
    '';

    postBuild = ''
    '';

    meta = with lib; {
      description = "Scout agent worker for gsmlg_umbrella";
      mainProgram = "gsmlg_scout_agent";
    };
  }
