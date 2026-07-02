# NixOS module for the Yellow Dog DHCP client service.
#
# Usage in flake.nix:
#   nixosModules.dhcpClient = import ./nix/dhcp-client-module.nix;
#
# Configuration example:
#   services.yellowdog-dhcp-client = {
#     enable = true;
#     package = self.packages.${system}.yellow_dog;
#     interfaces = {
#       eth0 = {
#         mode = "standalone";
#         manageDns = true;
#         dnsMethod = "resolvconf";
#       };
#       wlan0 = {
#         mode = "hook";
#         hookBackend = "networkmanager";
#       };
#     };
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.services.yellowdog-dhcp-client;

  interfaceOpts = { name, ... }: {
    options = {
      mode = lib.mkOption {
        type = lib.types.enum [ "standalone" "hook" ];
        default = "standalone";
        description = "Operating mode: standalone manages IP/routes/DNS directly, hook delegates to NetworkManager.";
      };

      vendorClass = lib.mkOption {
        type = lib.types.str;
        default = "YellowDog";
        description = "DHCP vendor class identifier (Option 60).";
      };

      selectionWindowMs = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "Time in ms to collect DHCP offers before selecting the best one.";
      };

      dadEnabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Duplicate Address Detection (ARP probes) after receiving ACK.";
      };

      dadProbes = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of ARP probes for DAD.";
      };

      dadWaitMs = lib.mkOption {
        type = lib.types.int;
        default = 2000;
        description = "Total wait time in ms for DAD probes.";
      };

      manageRoutes = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to manage default routes (standalone mode only).";
      };

      manageDns = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to manage DNS resolver config (standalone mode only).";
      };

      dnsMethod = lib.mkOption {
        type = lib.types.enum [ "resolvconf" "direct" "systemd-resolved" ];
        default = "resolvconf";
        description = "DNS configuration method (standalone mode only).";
      };

      hookBackend = lib.mkOption {
        type = lib.types.enum [ "networkmanager" "systemd-networkd" ];
        default = "networkmanager";
        description = "Backend to delegate to (hook mode only).";
      };
    };
  };

  # Generate the TOML config file from NixOS options
  tomlConfig = let
    interfaceConfigs = lib.concatStringsSep "\n" (lib.mapAttrsToList (iface: icfg: ''
      [dhcp_client.${iface}]
      interface = "${iface}"
      mode = "${icfg.mode}"
      vendor_class = "${icfg.vendorClass}"
      selection_window_ms = ${toString icfg.selectionWindowMs}
      dad_enabled = ${lib.boolToString icfg.dadEnabled}
      dad_probes = ${toString icfg.dadProbes}
      dad_wait_ms = ${toString icfg.dadWaitMs}
    '' + lib.optionalString (icfg.mode == "standalone") ''

      [dhcp_client.${iface}.standalone]
      manage_routes = ${lib.boolToString icfg.manageRoutes}
      manage_dns = ${lib.boolToString icfg.manageDns}
      dns_method = "${icfg.dnsMethod}"
    '' + lib.optionalString (icfg.mode == "hook") ''

      [dhcp_client.${iface}.hook]
      backend = "${icfg.hookBackend}"
    '') cfg.interfaces);
  in pkgs.writeText "yellowdog-dhcp-client.toml" interfaceConfigs;

in {
  options.services.yellowdog-dhcp-client = {
    enable = lib.mkEnableOption "Yellow Dog DHCP client";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Yellow Dog package to use.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a custom TOML config file. If set, overrides the generated config.";
    };

    interfaces = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule interfaceOpts);
      default = {};
      description = "Per-interface DHCP client configuration.";
    };

    leaseDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/yellowdog/leases";
      description = "Directory for persisted lease files.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Disable dhcpcd on managed interfaces to avoid conflicts
    networking.dhcpcd.denyInterfaces = lib.attrNames cfg.interfaces;

    systemd.tmpfiles.rules = [
      "d ${cfg.leaseDir} 0750 root root -"
      "d /run/yellowdog 0750 root root -"
    ];

    systemd.services.yellowdog-dhcp-client = {
      description = "Yellow Dog DHCP Client";
      after = [ "network-pre.target" ];
      before = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        YELLOW_DOG_CONFIG = if cfg.configFile != null then cfg.configFile else tomlConfig;
        RELEASE_COOKIE = "yellowdog_dhcp_client";
      };

      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/yellow_dog start";
        Restart = "on-failure";
        RestartSec = "2s";

        # Capabilities for raw sockets (ARP/DAD) and interface management
        AmbientCapabilities = "CAP_NET_RAW CAP_NET_ADMIN";
        CapabilityBoundingSet = "CAP_NET_RAW CAP_NET_ADMIN";

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;

        ReadWritePaths = [
          cfg.leaseDir
          "/run/yellowdog"
        ];
      };
    };
  };
}
