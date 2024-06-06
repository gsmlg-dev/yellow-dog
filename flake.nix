{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-docker-utils.url = "github.com:Gao-OS/flake-docker-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    flake-docker-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      yellowdogdns = pkgs.callPackage ./default.nix {inherit system;};
      dockerImage = pkgs.dockerTools.buildImage {
        name = "yellowdogdns";
        tag = "latest";
        created = "now";
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          paths = [
            pkgs.busybox
            pkgs.dockerTools.usrBinEnv
            pkgs.dockerTools.binSh
            pkgs.dockerTools.caCertificates
            pkgs.dockerTools.fakeNss
            yellowdogdns
          ];
          pathsToLink = ["/bin" "/etc" "/var"];
        };

        config = {
          Entrypoint = ["/bin/yellow_dog"];
          Cmd = ["start"];
          Env = [
            "REPLACE_OS_VARS=true"
            "ERL_EPMD_PORT=4369"
            "ERLCOOKIE=96myjWoLCTZRko08UdngkxQo/SwP9vfga28/B6IL"
            "POOL_SIZE=10"
            "RELEASE_COOKIE=3swYaASXT0ARmMHUjiDsesPesG0hh/SMQbQx6kX4+Z6+9S9YA2lS6lVNdQiX93Wv"
          ];
        };
      };
    in {
      packages.yellowdogdns = yellowdogdns;

      packages.docker = dockerImage;

      packages.allImages = flake-docker-utils.lib.allImages ["x86_64-linux" "aarch64-linux"] dockerImage;

      defaultPackage = yellowdogdns;
    });
}
