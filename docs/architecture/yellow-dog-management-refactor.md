# YellowDog Management Refactor Foundation

This refactor splits YellowDog management into three YellowDog-prefixed top-level
runtimes:

- `yellow_dog_management_core`
- `yellow_dog_server`
- `yellow_dog_netman`

The combined `yellow_dog` release can remain for development compatibility, but
the production architecture is centered on those three runtimes.

## Naming Guardrails

The management model uses concrete server and Netman concepts. It must not
introduce a generic node domain model.

Do not define:

- `YellowDog.Domain.Node`
- `YellowDog.Management.Node`
- `YellowDog.Node`
- `YellowDog.NodeRole`
- `YellowDog.NodeProfile`

Do not split server behavior into separate cloud/local runtime apps. These apps
must not be created:

- `yellow_dog_cloud_dns`
- `yellow_dog_local_server`

Cloud DNS and local network behavior are profiles of `yellow_dog_server`, not
separate applications.

## Runtime Responsibilities

### `yellow_dog_management_core`

`yellow_dog_management_core` owns management-facing state and APIs:

- server records
- server profiles
- Netman records
- Netman profiles
- published config versions
- applied config status
- drift and event records
- future enrollment and sync foundations

Management resources should stay concrete, for example:

- `YellowDog.Management.Server`
- `YellowDog.Management.ServerProfile`
- `YellowDog.Management.Netman`
- `YellowDog.Management.NetmanProfile`
- `YellowDog.Management.ConfigVersion`
- `YellowDog.Management.Event`

### `yellow_dog_server`

`yellow_dog_server` is a profile-driven service runtime. It starts server-side
services from the resolved server profile and explicit service flags.

Supported foundation profiles:

- `cloud_dns`
- `local_network`
- `dns_only`
- `dhcp_only`
- `netboot_only`
- `custom`

Supported server services:

- `dns`
- `mdns`
- `dhcpv4`
- `dhcpv6`
- `netboot`
- `identity`
- `fingerprint`
- `server_agent`

`cloud_dns` means DNS plus server agent. `local_network` means DNS, mDNS,
DHCPv4, DHCPv6, netboot, identity, fingerprint, and server agent. `custom`
starts from disabled service defaults and relies on explicit flags.

The new config shape is:

```toml
[yellow_dog_server]
id = "srv-cloud-dns-01"
name = "Cloud DNS 01"
profile = "cloud_dns"

[yellow_dog_server.services]
dns = true
server_agent = true
```

When `[yellow_dog_server]` is absent, server profile resolution falls back to
legacy `[core]` flags. This fallback must not change
`YellowDog.Config.service_enabled?/1`; legacy callers can keep using the
existing API during migration.

### `yellow_dog_netman`

`yellow_dog_netman` is a profile-driven network-management runtime. It can run
on local servers, cloud servers, bare-metal hosts, VMs, VPN gateways, and
observe-only hosts.

Supported foundation profiles:

- `local_server`
- `cloud_server`
- `bare_metal`
- `vm`
- `vpn_gateway`
- `observe_only`
- `custom`

Supported Netman features:

- `interfaces`
- `dhcp_client`
- `dns_client`
- `routes`
- `link_state`
- `vpn`

`local_server` defaults to `apply_mode = managed`. `cloud_server` defaults to
`apply_mode = observe_first`. `vpn_gateway` sets `vpn = true` only as resolved
configuration state; this foundation does not implement tunnels.

The new config shape is:

```toml
[yellow_dog_netman]
id = "netman-cloud-app-01"
name = "Cloud App 01 Netman"
profile = "cloud_server"

[yellow_dog_netman.features]
interfaces = true
dhcp_client = true
dns_client = true
routes = true
vpn = false

[yellow_dog_netman.mode]
apply = "observe_first"
```

## Console Management Section

The console gains a top-level Management section for service-node management.
It is not called "Node Management".

The section manages concrete `yellow_dog_server` and `yellow_dog_netman`
service nodes:

- Management Overview
- Servers
- Server Profiles
- Server Service Status
- DNS Servers
- DHCP Servers
- Cloud DNS Servers
- Local Network Servers
- Netman
- Netman Profiles
- Interfaces
- Routes
- DNS Client
- DHCP Client
- VPN placeholder
- Config Versions
- Applied Status and Drift
- Server Events
- Netman Events
- Audit Logs

Console pages should depend on management facades and profile/status data, not
direct protocol internals.
