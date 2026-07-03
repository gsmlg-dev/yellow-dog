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
  cargoRoot = "apps/abyss/native/dhcp_socket";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./.;
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    # nix will complain and tell you the right value to replace this with
    hash = "sha256-ziyUBavDvp5bY6knOr6NfYX0cOGl3DP3IUpb/OGLxO8=";
    mixEnv = "prod"; # default is "prod", when empty includes all dependencies, such as "dev", "test".
    # if you have build time environment variables add them here
    RELEASE_COOKIE = "Best_in_the_World!";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit src cargoRoot;
    hash = "sha256-VnGOU+mS57W5Z4Vbi0GmVVZiuPrmph14ocST+dQJSvk=";
  };

  exTursoPrecompiledNif = pkgs.fetchurl {
    url = "https://github.com/gsmlg-dev/ex_turso/releases/download/v0.2.1/libex_turso-v0.2.1-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz";
    hash = "sha256-5e/4LanWZxc8WOO4Ah0KrklgL3+ZFL+erhfSj+6/wKQ=";
  };

  exTursoPrecompiledCache = pkgs.linkFarm "ex-turso-precompiled-cache" [
    {
      name = "libex_turso-v0.2.1-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz";
      path = exTursoPrecompiledNif;
    }
  ];
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps cargoDeps cargoRoot;

    mixReleaseName = "yellow_dog";

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      pkgs.cargo
      pkgs.rustc
    ];

    # WORKAROUND(upstream): gsmlg-dev/ex_turso#6
    RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = exTursoPrecompiledCache;

    preBuild = ''
      mkdir -p deps/ex_turso/priv/native
    '';

    postBuild = ''
    '';

    meta = with lib; {
      description = "YellowDog Server for GSMLG.dev";
      mainProgram = "yellow_dog";
    };
  }
