{
  lib,
  pkgs,
  beam28Packages,
  releaseName ? "yellow_dog_worker",
  ...
}: let
  supportedReleases = ["yellow_dog_management" "yellow_dog_worker"];
  versionLines = lib.splitString "\n" (builtins.readFile ./mix.exs);
  versionLine = builtins.head (builtins.filter (line: builtins.match "[[:space:]]+version:.*" line != null) versionLines);
  version = builtins.elemAt (lib.splitString "\"" versionLine) 1;

  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type: let
      relative = lib.removePrefix "${toString ./.}/" (toString path);
      topLevel = builtins.head (lib.splitString "/" relative);
    in
      lib.cleanSourceFilter path type
      && !(builtins.elem topLevel ["_build" "deps" "node_modules" ".trees" ".devenv" ".direnv" "data" "tmp" "nonode@nohost"])
      && !(lib.hasPrefix ".env" topLevel)
      && !(lib.hasInfix "/native/" relative && (lib.hasInfix "/target/" relative || lib.hasSuffix "/target" relative));
  };

  mixFodDeps = beam28Packages.fetchMixDeps {
    pname = "yellow-dog-phase1-mix-deps";
    inherit src version;
    hash = "sha256-rS1h4h93FxU2y1fdRsQ/yR5anvyLhdBqN0mu6QMvExc=";
    mixEnv = "prod";
  };

  # Rustler precompiled downloads must be declared inputs to the sandboxed build.
  mdexTarget = {
    x86_64-linux = "x86_64-unknown-linux-gnu";
    aarch64-linux = "aarch64-unknown-linux-gnu";
  }.${pkgs.stdenv.hostPlatform.system};
  mdexHashes = {
    x86_64-linux = "a47f7d480d0773ba35695c3de1b48932cbe80d151675ae2ef3c833cdac8037b2";
    aarch64-linux = "bcb15d23ec2fab316ffd0bce711af8e84b23d6779d665b933a5be6ff6d48961a";
  };
  mdexArtifact = pkgs.fetchurl {
    name = "libmdex_native_nif-v0.3.2-nif-2.15-${mdexTarget}.so.tar.gz";
    url = "https://github.com/leandrocp/mdex_native/releases/download/v0.3.2/libmdex_native_nif-v0.3.2-nif-2.15-${mdexTarget}.so.tar.gz";
    sha256 = mdexHashes.${pkgs.stdenv.hostPlatform.system};
  };
in
  assert builtins.elem releaseName supportedReleases;
    (beam28Packages.mixRelease {
      pname = releaseName;
      inherit version src mixFodDeps;
      mixReleaseName = releaseName;
      compileFlags = ["--warnings-as-errors"];
      preConfigure = ''
        export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$TMPDIR/rustler-precompiled"
        mkdir -p "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"
        cp ${mdexArtifact} "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/${mdexArtifact.name}"
      '';
      passthru = {inherit mixFodDeps;};
      meta = {
        description = "Independent YellowDog Phase 1 ${releaseName}";
        mainProgram = releaseName;
        platforms = lib.platforms.linux;
      };
    }).overrideAttrs (previous: {
      postFixup = previous.postFixup + lib.optionalString (releaseName == "yellow_dog_worker") ''
        wrapProgram "$out/bin/yellow_dog_worker" \
          --prefix PATH : ${lib.makeBinPath [pkgs.util-linux pkgs.coreutils pkgs.bash]}
      '';
    })
