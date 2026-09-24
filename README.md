# Yellow Dog

![Yellow Dog](./priv/yellow_dog.png)

Yellow Dog is a distributed DNS, DHCP, mDNS, and network-management suite written in Elixir/Erlang. It is an Elixir umbrella project with a Phoenix LiveView console, protocol libraries, a managed server runtime, and a separate Linux network-manager runtime.

The umbrella currently builds three production releases:

- `yellow_dog_management_core` — management records, profiles, events, and the management console.
- `yellow_dog_server` — DNS, mDNS, DHCPv4/v6, netboot, identity, fingerprinting, tasks, and the server agent.
- `yellow_dog_netman` — DHCP client, DNS stub resolution, Linux network reconciliation, and the Netman agent.

The combined `yellow_dog` release remains available for development compatibility; production workflows build and validate the three runtimes above.

## Features

- Authoritative and forwarding DNS with views, zones, ACLs, and TCP support
- mDNS service registration and discovery
- DHCPv4 and DHCPv6 servers with persistent lease management
- TFTP/iPXE network boot support
- Device identity and passive DHCP fingerprinting
- Concord-backed server state with a write-through ETS read cache
- Profile-driven management and Phoenix LiveView operations console
- A Linux network-manager runtime with DHCP client and netlink integration

## Quick start

The development environment uses devenv. Activate it before running Mix commands:

```shell
direnv allow
# or: devenv shell

mix deps.get
mix compile
```

Run the combined development runtime:

```shell
mix run --no-halt
```

Run an individual runtime through the Mix aliases:

```shell
mix server.run
mix netman.run
mix console.run
```

The console can also be started directly:

```shell
cd apps/yellow_dog_console
mix phx.server
```

Open <http://localhost:4270>. Production console startup requires `PHX_SERVER=true`, `SECRET_KEY_BASE`, and the usual Phoenix host/port settings.

### Default ports

The defaults below include privileged ports. Use `--config` or a service-specific TOML setting when running without the required operating-system privileges.

| Service | Port | Transport |
| --- | ---: | --- |
| DNS | 53 | UDP and optional TCP |
| mDNS | 5353 | UDP multicast/unicast |
| DHCPv4 | 67 | UDP |
| DHCPv6 | 547 | UDP |
| TFTP | 69 | UDP |
| Web console | 4270 | HTTP |

## Architecture

The repository contains 25 umbrella applications grouped by responsibility:

| Group | Applications |
| --- | --- |
| Management | `yellow_dog_management_core`, `yellow_dog_server_agent`, `yellow_dog_netman_agent`, `yellow_dog_sync`, `yellow_dog_tasks` |
| Core and state | `yellow_dog`, `yellow_dog_config`, `yellow_dog_store`, `yellow_dog_telemetry` |
| Protocol services | `yellow_dog_dns`, `yellow_dog_dns_provider`, `yellow_dog_dhcpv4`, `yellow_dog_dhcpv6`, `yellow_dog_mdns`, `yellow_dog_netboot` |
| Host and client services | `yellow_dog_dhcp_client`, `yellow_dog_netman`, `yellow_dog_resolved`, `yellow_dog_identity`, `yellow_dog_fingerprint` |
| Console | `yellow_dog_console` |
| Libraries | `abyss`, `ex_dns`, `ex_dhcp`, `geo_ip_db` |

Protocol servers follow the `Server` → `Handler` → `Supervisor` pattern and use the Abyss socket abstraction. The server release owns service orchestration and Store access. The Netman release is intentionally independent of `yellow_dog_store`; its lease data is local TOML state.

`yellow_dog_store` uses Concord as the source of truth and ETS as a write-through local read cache. DHCPv4/v6 lease allocation still uses Mnesia `disc_copies` tables, while DNS view/zone state is accessed through the Store facades. Server applications must not call `Concord.*` directly.

The core API exposes configuration and service status for development and console integrations:

```elixir
YellowDog.get_all_config()
YellowDog.get_all_status()
YellowDog.get_service_status(:dns)
YellowDog.list_services()
```

## Configuration

Configuration is TOML-based. In development the default file is `priv/yellow_dog_default_config.toml`; release applications use the copy under the owning app's `priv/` directory. The file can be selected with the CLI or environment:

```shell
mix run --no-halt -- --config /etc/yellowdog/config.toml
YELLOW_DOG_CONFIG=/etc/yellowdog/config.toml mix server.run
YELLOW_DOG_DATA_DIR=/var/lib/yellowdog mix server.run
```

`--config` takes precedence over `YELLOW_DOG_CONFIG`, which takes precedence over the environment-specific default. `--data-dir` takes precedence over `YELLOW_DOG_DATA_DIR` and the TOML `data_dir` value. Scheduled jobs use the separate `--tasks-config` and `YELLOW_DOG_TASKS_CONFIG` settings.

A minimal configuration looks like this:

```toml
data_dir = "data"

[core]
dns = true
mdns = false
dhcpv4 = false
dhcpv6 = false
netboot = false

[dns]
listen = "0.0.0.0"
port = 53
tcp_enabled = true

[dns.zones]
"example.com" = { type = "authoritative", file = "priv/zones/example.com.zone" }
```

Runtime configuration also supports Concord clustering (`CONCORD_CLUSTERING`, `CONCORD_CLUSTER_NODES`, and `CONCORD_DATA_DIR`), management/server agent settings, and Phoenix console authentication (`CONSOLE_AUTH_ENABLED`, `CONSOLE_USERNAME`, and `CONSOLE_PASSWORD`). See `config/runtime.exs` for the complete precedence and environment-variable list.

## Data and persistence

All relative data paths resolve below the configured `data_dir` (default `data/`). Typical service directories are:

```text
data/
├── dns/          # views, zones, and DNS service data
├── mdns/         # registered service data
├── dhcpv4/       # DHCPv4 lease and pool data
├── dhcpv6/       # DHCPv6 lease and pool data
├── fingerprint/  # device fingerprint data
├── mnesia/       # Mnesia table files
└── store/        # managed config/store state when enabled
```

Treat the data directory as runtime state. Back it up before changing configuration or upgrading a release.

## Development and validation

```shell
# Compile and run unit tests
mix compile --warnings-as-errors
mix test

# Formatting and linting
mix format --check-formatted
mix credo --strict
mix lint

# E2E suites
mix test.e2e
mix test.e2e.dns
mix test.e2e.dhcpv4
mix test.e2e.management
```

E2E tests choose non-privileged ports where possible. The Netman release requires Linux kernel networking support and a Rust toolchain for its native netlink helper. Release smoke checks are available for all three releases:

```shell
scripts/e2e/release_smoke.sh yellow_dog_management_core
scripts/e2e/release_smoke.sh yellow_dog_server
scripts/e2e/release_smoke.sh yellow_dog_netman
```

The CI workflows in `.github/workflows/` run the test, E2E, multi-architecture Docker, and release checks. Do not disable a CI job to hide a failure.

## Web console assets

The console uses Phoenix LiveView and DuskMoon components. DuskmoonBundler owns JavaScript and CSS compilation:

```shell
cd apps/yellow_dog_console
mix setup
mix assets.build
mix assets.deploy
```

## Docker and Nix

Build the Nix package or Docker image from the repository root:

```shell
nix build .#yellow_dog
nix build .#docker
```

The GitHub Docker workflow publishes multi-architecture images to GitHub Container Registry. For local development, prefer the Mix runtimes above so that the selected profile and data directory are explicit.

## License

Yellow Dog is open source software.
