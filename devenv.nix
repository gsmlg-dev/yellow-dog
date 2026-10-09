{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
in {
  env.GREET = "YellowDog";
  env.PGDATABASE = "yellow_dog_management_dev";
  env.YELLOW_DOG_MANAGEMENT_DATABASE_URL = "postgresql://yellow_dog@localhost:${toString config.env.PGPORT}/${config.env.PGDATABASE}?socket_dir=${config.env.PGHOST}";
  env.YELLOW_DOG_MANAGEMENT_PORT = "4270";

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_16;
    listen_addresses = "";
    createDatabase = false;
    settings.unix_socket_permissions = "0700";
    hbaConf = ''
      local all all trust
    '';
    initialScript = ''
      CREATE ROLE yellow_dog WITH LOGIN CREATEDB;
    '';
  };

  processes.management = {
    after = ["devenv:processes:postgres"];
    cwd = "${config.devenv.root}/apps/yellow_dog_management";
    env = {
      YELLOW_DOG_MANAGEMENT_BIND_ADDRESS = "0.0.0.0";
      YELLOW_DOG_WORKER_BOOTSTRAP = "${config.devenv.state}/worker/bootstrap.toml";
      YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY = "${config.devenv.state}/management/artifacts";
      YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY = "${config.devenv.state}/management/backups";
    };
    exec = ''
      set -euo pipefail
      umask 077
      mix run --no-start -e 'YellowDog.Management.Release.setup()'
      exec mix run --no-halt ../../scripts/devenv/management.exs
    '';
    ready = {
      exec = ''
        test -s "$YELLOW_DOG_WORKER_BOOTSTRAP" &&
        curl --fail --silent --max-time 2 http://127.0.0.1:$YELLOW_DOG_MANAGEMENT_PORT/api/workers > /dev/null
      '';
      initial_delay = 2;
      period = 2;
      probe_timeout = 3;
      failure_threshold = 60;
    };
  };

  processes.worker = {
    after = ["devenv:processes:management"];
    cwd = "${config.devenv.root}/apps/yellow_dog_worker";
    env.YELLOW_DOG_WORKER_BOOTSTRAP = "${config.devenv.state}/worker/bootstrap.toml";
    exec = "exec mix run --no-halt";
    ready = {
      exec = ''
        worker_id=$(sed -n 's/^worker_id = "\([^"]*\)"$/\1/p' "$YELLOW_DOG_WORKER_BOOTSTRAP")
        curl --fail --silent --max-time 2 "http://127.0.0.1:$YELLOW_DOG_MANAGEMENT_PORT/api/workers/$worker_id" |
          jq -e '.data.connection_status == "connected"' > /dev/null
      '';
      initial_delay = 2;
      period = 2;
      probe_timeout = 3;
      failure_threshold = 60;
    };
  };

  packages = with pkgs-stable;
    [
      git
      figlet
      lolcat
      watchman
      beam28Packages.elixir-ls
      coreutils
      curl
      jq
    ]
    ++ lib.optionals stdenv.isLinux [
      inotify-tools
      util-linux
    ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.rust.enable = true;

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  enterShell = ''
    hello
  '';
}
