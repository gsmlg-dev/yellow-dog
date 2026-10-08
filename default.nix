{
  lib,
  pkgs,
  beam28Packages,
  rustPlatform,
  releaseName ? "yellow_dog_worker",
  ...
}: let
  supportedReleases = ["yellow_dog_management" "yellow_dog_worker"];
  versionLines = lib.splitString "\n" (builtins.readFile ./mix.exs);
  versionLine = builtins.head (builtins.filter (line: builtins.match "[[:space:]]+version:.*" line != null) versionLines);
  version = builtins.elemAt (lib.splitString "\"" versionLine) 1;
  cargoRoot = "apps/abyss/native/dhcp_socket";

  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type: let
      relative = lib.removePrefix "${toString ./.}/" (toString path);
      topLevel = builtins.head (lib.splitString "/" relative);
    in
      lib.cleanSourceFilter path type
      && !(builtins.elem topLevel ["_build" "deps" "node_modules" ".trees" ".devenv" ".direnv" "data" "tmp" "nonode@nohost"])
      && !(lib.hasPrefix ".env" topLevel)
      && !(lib.hasInfix "/native/" relative && (lib.hasInfix "/target/" relative || lib.hasSuffix "/target" relative))
      && relative != "apps/abyss/priv/native/dhcp_socket.so";
  };

  mixFodDeps = beam28Packages.fetchMixDeps {
    pname = "yellow-dog-phase1-mix-deps";
    inherit src version;
    hash = "sha256-29Xmw8SMUhjj9omSnf5s+CRqW4eFp5j70YC0iI2PNPQ=";
    mixEnv = "prod";
  };

  # Rustler precompiled downloads must be declared inputs to the sandboxed build.
  mdexTarget = {
    x86_64-linux = "x86_64-unknown-linux-gnu";
    aarch64-linux = "aarch64-unknown-linux-gnu";
  }.${pkgs.stdenv.hostPlatform.system};
  mdexHashes = {
    x86_64-linux = "963238414ea5a6bb4545986c09c825dffcd75e9327db9ab7306fb1aa6cbd4cec";
    aarch64-linux = "1aa43e45b47d5cf3e0f1b7aed8bfd24fdbcc7e2f4a976f9ad53bfc7af92facf7";
  };
  mdexArtifact = pkgs.fetchurl {
    name = "libmdex_native_nif-v0.2.8-nif-2.15-${mdexTarget}.so.tar.gz";
    url = "https://github.com/leandrocp/mdex_native/releases/download/v0.2.8/libmdex_native_nif-v0.2.8-nif-2.15-${mdexTarget}.so.tar.gz";
    sha256 = mdexHashes.${pkgs.stdenv.hostPlatform.system};
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit src cargoRoot;
    hash = "sha256-VnGOU+mS57W5Z4Vbi0GmVVZiuPrmph14ocST+dQJSvk=";
  };
in
  assert builtins.elem releaseName supportedReleases;
    (beam28Packages.mixRelease {
      pname = releaseName;
      inherit version src mixFodDeps cargoDeps cargoRoot;
      mixReleaseName = releaseName;
      compileFlags = ["--warnings-as-errors"];
      nativeBuildInputs = [rustPlatform.cargoSetupHook pkgs.cargo pkgs.rustc];
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
