{defaultPackage ? null}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.yellow-dog-worker;
in {
  options.services.yellow-dog-worker = {
    enable = lib.mkEnableOption "Yellow Dog Worker";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = defaultPackage;
      description = "Worker release package. Required when enabled without a flake-provided default.";
    };

    bootstrapFile = lib.mkOption {
      type = lib.types.strMatching "/[^\n\r]+";
      description = ''
        Absolute runtime path to the private Worker bootstrap TOML. Use a string,
        not a Nix path or generated store file: the bootstrap contains a token.
        systemd copies it through LoadCredential. Set data_dir to
        /var/lib/yellow-dog-worker, and use absolute source and TLS file paths
        because bootstrap-relative paths then resolve inside the credentials directory.
        Additional private TLS files may be supplied through the service's native
        systemd LoadCredential configuration; refer to their absolute runtime paths.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.yellow-dog-worker.package must provide a Worker release package.";
      }
      {
        assertion =
          cfg.bootstrapFile
          != "/nix/store"
          && !(lib.hasPrefix "/nix/store/" cfg.bootstrapFile);
        message = "services.yellow-dog-worker.bootstrapFile must be a private runtime file outside /nix/store.";
      }
    ];

    users.groups.yellow-dog-worker = {};
    users.users.yellow-dog-worker = {
      isSystemUser = true;
      group = "yellow-dog-worker";
    };

    systemd.services.yellow-dog-worker = lib.mkIf (cfg.package != null) {
      description = "Yellow Dog Worker";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      environment = {
        YELLOW_DOG_WORKER_BOOTSTRAP = "%d/bootstrap.toml";
        RELEASE_DISTRIBUTION = "none";
      };
      script = ''
        export RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64)"
        exec ${cfg.package}/bin/yellow_dog_worker start
      '';
      serviceConfig = {
        User = "yellow-dog-worker";
        Group = "yellow-dog-worker";
        StateDirectory = "yellow-dog-worker";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/yellow-dog-worker";
        LoadCredential = ["bootstrap.toml:${cfg.bootstrapFile}"];
        UMask = "0077";
        AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
        CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
        Restart = "on-failure";
        RestartSec = 5;
        # Send SIGTERM only to BEAM so its durable lock helpers survive owned shutdown.
        # systemd still kills remaining cgroup processes if shutdown times out.
        KillMode = "mixed";
        TimeoutStopSec = 45;
      };
    };
  };
}
