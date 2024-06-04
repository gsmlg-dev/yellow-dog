{
  lib,
  pkgs,
  buildNpmPackage,
  beamPackages,
  nodejs,
  ...
}: let
  pname = "yellow_dog";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./.;
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    # nix will complain and tell you the right value to replace this with
    hash = "sha256-sZgrfqjP8ytzWE8YlnXddQve7eClmFOCb4nOy1Zl8Ro=";
    mixEnv = "prod"; # default is "prod", when empty includes all dependencies, such as "dev", "test".
    # if you have build time environment variables add them here
    RELEASE_COOKIE = "Best_in_the_World!";
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
      description = "YellowDog NameServer for GSMLG.dev";
      mainProgram = "yellow_dog";
    };
  }
