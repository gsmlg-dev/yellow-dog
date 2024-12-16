{
  lib,
  pkgs,
  buildNpmPackage,
  beamPackages,
  nodejs,
  ...
}: let
  mix-file = builtins.readFile ./mix.exs;
  lines = builtins.split "\n" mix-file;
  lines_s = builtins.filter builtins.isString lines;
  versionLine = builtins.elemAt (builtins.filter (line: builtins.match "[[:space:]]+version:.*" line != null) lines_s) 0; # Get the first matching line
  version_in_mix = builtins.elemAt (builtins.split "\"" versionLine) 2; # Extract version between quotes

  pname = "yellow_dog";
  version = version_in_mix;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./.;
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    # nix will complain and tell you the right value to replace this with
    hash = "sha256-WNdN6mDQb8rmLLplPZV4B6ACz4rz9RCMk3uzdC6Widk=";
    mixEnv = "prod"; # default is "prod", when empty includes all dependencies, such as "dev", "test".
    # if you have build time environment variables add them here
    RELEASE_COOKIE = "Best_in_the_World!";
  };
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps;

    mixReleaseName = "yellow_dog";

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
