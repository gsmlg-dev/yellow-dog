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

  packages = with pkgs-stable;
    [
      git
      figlet
      lolcat
      watchman
      beam28Packages.elixir-ls
      coreutils
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
