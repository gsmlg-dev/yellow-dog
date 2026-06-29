{
  lib,
  pkgs,
  buildNpmPackage,
  beamPackages,
  nodejs,
  rustPlatform,
  ...
}: let
  mix-file = builtins.readFile ./mix.exs;
  lines = builtins.split "\n" mix-file;
  lines_s = builtins.filter builtins.isString lines;
  versionLine = builtins.elemAt (builtins.filter (line: builtins.match "[[:space:]]+version:.*" line != null) lines_s) 0; # Get the first matching line
  version_in_mix = builtins.elemAt (builtins.split "\"" versionLine) 2; # Extract version between quotes

  pname = "yellow_dog";
  version = version_in_mix;
  cargoRoot = "apps/yellow_dog_dhcp_client/native/dhcp_socket";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./.;
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    # nix will complain and tell you the right value to replace this with
    hash = "sha256-A2IfJYZ2dAkhkJPpi3Sr6H1s9/kqtoMHWmasoJYyA+Q=";
    mixEnv = "prod"; # default is "prod", when empty includes all dependencies, such as "dev", "test".
    # if you have build time environment variables add them here
    RELEASE_COOKIE = "Best_in_the_World!";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit src cargoRoot;
    hash = "sha256-NhRYCyn4uaMNHOSj5ya6IpQ/kXeo+b+rgMOH4xkA7Tw=";
  };
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps cargoDeps cargoRoot;

    mixReleaseName = "yellow_dog";

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      pkgs.cargo
      pkgs.rustc
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
