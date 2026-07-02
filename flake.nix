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
    {
      nixosModules.dhcpClient = import ./nix/dhcp-client-module.nix;
      nixosModules.default = self.nixosModules.dhcpClient;
    } //
    flake-utils.lib.eachDefaultSystem (system: let
      yellow_dog_default_config =
        pkgs.writeText "yellowdog.toml"
        ''
          [server]
          port = 53
          logging-facility = "local0"
          logging-level = "warning"
          console = true
          bind = ["any"]
          ipv4-only = false
          ipv6-only = false
          telemetry = false
          padding = true
          reporting-agent = ""
          report-via-dns = false

          [forwarder]
          server = "8.8.8.8"
          override-ecs = false
          ecs-addr = "114.249.114.18"
          ecs-prefix = 24
        '';
      pkgs = import nixpkgs {inherit system;};
      yellow_dog = pkgs.callPackage ./default.nix {inherit system;};
      dockerImage = pkgs.dockerTools.buildImage {
        name = "yellow_dog";
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
            pkgs.locale
            pkgs.tzdata
            pkgs.glibcLocales
            yellow_dog
            # yellow_dog_default_config
          ];
          pathsToLink = ["/bin" "/etc" "/var"];
        };

        config = {
          Entrypoint = ["/bin/yellow_dog"];
          Cmd = ["start"];
          WorkingDir = "/root";
          Labels = {
            "org.opencontainers.image.source" = "https://github.com/gsmlg-dev/yellow-dog";
            "org.opencontainers.image.version" = "${yellow_dog.version}";
            "org.opencontainers.image.title" = "YellowDog";
            "org.opencontainers.image.description" = "A DNS Server write in Elixir";
            "maintainer" = "Jonathan Gao <gsmlg.com@gmail.com>";
            "volume.config" = "/etc/yellowdog.toml";
          };
          Env = [
            # "TZ=Asia/Shanghai"
            "LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive"
            "LANG=en_US.UTF-8"
            "LANGUAGE=en_US:en"
            "LC_ALL=en_US.UTF-8"
            "REPLACE_OS_VARS=true"
            "ERL_EPMD_PORT=4369"
            "ERLCOOKIE=96myjWoLCTZRko08UdngkxQo/SwP9vfga28/B6IL"
            "POOL_SIZE=10"
            "RELEASE_COOKIE=3swYaASXT0ARmMHUjiDsesPesG0hh/SMQbQx6kX4+Z6+9S9YA2lS6lVNdQiX93Wv"
          ];
          Volumes = {
            # "/etc/yellowdog.toml" = {};
          };
        };
      };
    in {
      packages =
        {
          yellow_dog = yellow_dog;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          docker = dockerImage;
        };

      defaultPackage = yellow_dog;

      devShells.default = pkgs.mkShell {
        name = "YellowDog Server Dev Shell";

        buildInputs = [
          pkgs.figlet
          pkgs.elixir
          pkgs.p7zip
          pkgs.rustPlatform.cargoSetupHook
          pkgs.cargo
          pkgs.rustc
        ];

        shellHook = ''
          figlet -w 120 -f starwars YellowDog
          figlet -w 120 -f starwars Server
          figlet -w 120 -f starwars Dev Shell

          export EDITOR=vim
        '';
      };
    });
}
