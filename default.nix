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
    hash = "sha256-z7gfXCRlr30IZwvCTdFaqkx4HG7NwoAkyXXVbhjAJzI=";
    mixEnv = "prod";
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
