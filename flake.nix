{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux"] (system: let
      pkgs = import nixpkgs {inherit system;};
      management = pkgs.callPackage ./default.nix {releaseName = "yellow_dog_management";};
      worker = pkgs.callPackage ./default.nix {releaseName = "yellow_dog_worker";};
      image = release:
        pkgs.dockerTools.buildLayeredImage {
          name = release.pname;
          tag = "latest";
          contents = [release pkgs.dockerTools.binSh pkgs.dockerTools.usrBinEnv pkgs.dockerTools.caCertificates pkgs.dockerTools.fakeNss];
          config = {
            Entrypoint = ["/bin/${release.pname}"];
            Cmd = ["start"];
            WorkingDir = "/";
            Env = ["LANG=C.UTF-8" "RELEASE_DISTRIBUTION=none"];
            Labels = {
              "org.opencontainers.image.source" = "https://github.com/gsmlg-dev/yellow-dog";
              "org.opencontainers.image.version" = release.version;
              "org.opencontainers.image.title" = release.pname;
            };
          };
        };
    in {
      packages = {
        yellow_dog_management = management;
        yellow_dog_worker = worker;
        default = worker;
        docker-management = image management;
        docker-worker = image worker;
      };
      devShells.default = pkgs.mkShell {
        packages = [pkgs.beam28Packages.elixir pkgs.cargo pkgs.rustc pkgs.postgresql_16 pkgs.util-linux pkgs.coreutils];
      };
      checks = pkgs.lib.optionalAttrs (system == "x86_64-linux") {
        worker = import ./nix/tests/worker.nix {
          inherit pkgs;
          workerPackage = worker;
          workerModule = self.nixosModules.worker;
        };
      };
    })
    // {
      nixosModules.worker = {pkgs, ...} @ args:
        import ./nix/worker-module.nix {
          defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.yellow_dog_worker;
        }
        args;
    };
}
