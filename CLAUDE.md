# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Sub-App Context

When working on files within a specific sub-app (`apps/<app_name>/`), read that sub-app's `CLAUDE.md` if it exists. Apps with their own CLAUDE.md: `abyss`, `ex_dhcp`, `ex_dns`, `yellow_dog_console`, `yellow_dog_dhcp_client`, `yellow_dog_netman`, `yellow_dog_store`.

## Project Overview

Yellow Dog is a distributed DNS/DHCP/mDNS/Netboot server written in Elixir using an umbrella project structure. Elixir 1.18 / OTP 27-28, Phoenix LiveView 1.0.

### Two Products, Three Releases

The umbrella builds separate Mix releases (root `mix.exs`):

- **`yellow_dog_server`** — server product: DNS, mDNS, DHCPv4/v6, netboot, identity, fingerprinting, console
- **`yellow_dog_netman`** — client product: NetworkManager replacement (netman, dhcp_client, mdns). Does NOT include Store or Concord
- **`yellow_dog`** — combined release with everything

### Applications (19 total)

| App | Location | Purpose |
|-----|----------|---------|
| **YellowDog** | `apps/yellow_dog/` | Core: orchestration, service manager, rate limiter |
| **YellowDog.Config** | `apps/yellow_dog_config/` | TOML config loading, schema, validation, writer |
| **YellowDog.Store** | `apps/yellow_dog_store/` | Unified data backend: Concord (Raft KV) + ETS cache facade, domain modules (Lease, Zone, Device, Rpz, Host, Cache), GenStage event bridge |
| **YellowDog.Telemetry** | `apps/yellow_dog_telemetry/` | Centralized telemetry and span management |
| **YellowDog.Dns** | `apps/yellow_dog_dns/` | DNS server: views, zones, name resolution, ACLs |
| **YellowDog.Dhcpv4** | `apps/yellow_dog_dhcpv4/` | DHCPv4 server: lease management, address pools |
| **YellowDog.Dhcpv6** | `apps/yellow_dog_dhcpv6/` | DHCPv6 server: DUID-based leases, IA_NA support |
| **YellowDog.DhcpClient** | `apps/yellow_dog_dhcp_client/` | DHCPv4 client: DORA handshake, vendor options, Abyss-backed NIF socket |
| **YellowDog.Mdns** | `apps/yellow_dog_mdns/` | mDNS responder: service discovery and registration |
| **YellowDog.Netboot** | `apps/yellow_dog_netboot/` | Network boot: TFTP server, iPXE scripts, device registry, HTTP boot |
| **YellowDog.Fingerprint** | `apps/yellow_dog_fingerprint/` | Passive DHCP fingerprinting for device identification |
| **YellowDog.Identity** | `apps/yellow_dog_identity/` | Host identity: registry, SSH key validation, trust verification, approval policies |
| **YellowDog.Netman** | `apps/yellow_dog_netman/` | Network manager: wired ethernet, DHCP/static IP, reconciliation engine, netlink |
| **YellowDog.Resolved** | `apps/yellow_dog_resolved/` | DNS stub resolver: intercept rules, cache, upstream forwarding, EDNS discovery |
| **YellowDogConsole** | `apps/yellow_dog_console/` | Phoenix LiveView web console (DuskMoon UI, Bun) |
| **GeoIpDb** | `apps/geo_ip_db/` | IP geolocation database library (MMDB format) |
| **Abyss** | `apps/abyss/` | UDP/server socket library (used by all protocol apps and DHCP client native sockets) |
| **ExDns** | `apps/ex_dns/` | DNS protocol library (messages, zones, records) |
| **ExDhcp** | `apps/ex_dhcp/` | DHCP protocol library (DHCPv4/v6 messages) |

Module naming: `YellowDog.<AppName>.ModuleName`. Infrastructure libs use own namespaces: `Abyss.*`, `DNS.*`, `DHCP.*`, `GeoIpDb.*`.

### Key Architecture Decisions

- Only four apps have `Application` modules: `yellow_dog` (core — starts/manages all server-side protocol apps), `yellow_dog_netman` (separate netman release entry point), `yellow_dog_console` (Phoenix), and `abyss` (minimal — a single `Abyss.TableOwner` process that owns the shared ETS tables). Everything else is a library application
- Services are conditionally started by `YellowDog.Application` via `service_enabled?(config, :service_name)` from TOML config
- Infrastructure libs (abyss, ex_dns, ex_dhcp) are **in-umbrella** with shared build paths
- All protocol servers follow the same pattern: `Server` (GenServer + Abyss) → `Handler` (Abyss.Handler behaviour) → `Supervisor` (conditional start)
- **Store** (`yellow_dog_store`) wraps Concord (Raft-based embedded KV) behind typed facade modules. Concord is the source of truth; ETS is the always-on local read cache (write-through). See `apps/yellow_dog_store/CLAUDE.md` for the full data-flow contract
- **Netman apps never depend on `yellow_dog_store`** — netman is a separate product with its own persistence (TOML lease files via `LeaseStore`)
- **DhcpClient** uses swappable implementations via Application env: `socket_impl` (Abyss-owned NIF in prod, `UdpFallback` in test) and `os_integration` (`Standalone` via `ip` commands, or `HookNM` for NetworkManager)

## Constitution (Architectural Constraints)

- **Do not use `:gen_udp` outside `apps/abyss/`** — All UDP socket operations (open, send, recv, close) must go through the Abyss abstraction layer (`Abyss.Client`, `Abyss.Transport.UDP`, or `Abyss.DhcpSocket.Native`). Exempt: protocol libraries `ex_dns` and `ex_dhcp` which have no Abyss dependency by design. **Exception:** `DhcpSocket.UdpFallback` in `apps/yellow_dog_dhcp_client/` is a dev/test-only socket stub that uses `:gen_udp`; production DHCP client sockets use the Abyss-owned Rust NIF via `DhcpSocket.Native`.
- **No server app calls `Concord.*` directly** — all access goes through `YellowDog.Store.*` facade modules

## Common Commands

```bash
# Run all tests (from umbrella root)
mix test

# Console tests specifically (MUST cd into app dir)
cd apps/yellow_dog_console && mix test

# Single test file
mix test apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/handler_test.exs

# E2E tests (auto-selects ports, CI-friendly; suites live in e2e_test/)
mix test.e2e                # All E2E
mix test.e2e.dns            # Per-service: .dns .mdns .dhcpv4 .dhcpv6 .netboot .zone.auth .zone.forward

# Build verification (CI pipeline)
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict

# Lint + Dialyzer (available per-app via `mix lint`, CI disables Dialyzer due to memory)
mix lint                    # from any app dir: runs credo --strict + dialyzer

# Start Phoenix console (dev)
cd apps/yellow_dog_console && mix phx.server    # http://localhost:4270

# Console setup (first time or after deps change)
cd apps/yellow_dog_console
mix setup                   # deps.get + assets.setup + assets.build

# Asset building
cd apps/yellow_dog_console
bun run build               # Dev
bun run build:prod          # Prod (minified)
# Note: Bun bundles JS; Tailwind CSS v4 runs as a standalone CLI (not via PostCSS)

# Pre-commit check (console only)
cd apps/yellow_dog_console && mix precommit     # compile + format + test

# Dev environment
direnv allow                # or: devenv shell
```

## Architecture

### Dependency Graph

```
YellowDog (core: orchestration) → yellow_dog_config + yellow_dog_store + abyss
├── YellowDog.Dns         → ex_dns + abyss + store + geo_ip_db + telemetry
├── YellowDog.Dhcpv4      → ex_dhcp + abyss + store + telemetry
├── YellowDog.Dhcpv6      → ex_dhcp + abyss + store + telemetry
├── YellowDog.Mdns        → ex_dns + abyss + store + telemetry
├── YellowDog.Netboot     → abyss + telemetry
├── YellowDog.Fingerprint → store + telemetry
├── YellowDog.Identity    → store + telemetry
├── YellowDog.DhcpClient  → ex_dhcp + abyss + telemetry   (no store)
├── YellowDog.Resolved    → abyss + ex_dns                (no store, no core)
├── YellowDog.Netman      → dhcp_client + resolved + ex_dhcp + telemetry (no store)
└── YellowDogConsole      → phoenix + all service apps + store + geo_ip_db
```

### Console Page Structure

LiveView pages in `apps/yellow_dog_console/lib/yellow_dog/console/live/`:

| Section | Pages | Key patterns |
|---------|-------|-------------|
| DNS | Overview, Views, Zones, Records, ACL, Query Logs, Metrics | Nested URL hierarchy: `/dns/views/:view/zones/:type/:name/records` |
| DHCPv4 | Overview, Leases, Pools, Activity | Telemetry-driven activity log via `:telemetry.attach_many` |
| DHCPv6 | Overview, Leases, Pools, Activity | DUID formatting, same telemetry pattern as DHCPv4 |
| mDNS | Overview, Services, Discovery, Monitor | PubSub real-time updates |
| Fingerprint | Devices, Device Detail, Fingerprints | Passive DHCP fingerprinting |
| Tools | GeoIP, Whois, MAC Lookup | Async `Task.async` + `handle_info` for network calls |
| System | Settings, Logs, Diagnostics, Process Map, Backups | TOML config persistence, process tree SVG |

### Console Component Architecture

- Layout: `Layouts.app` wraps all pages (`layouts.ex`), sidebar defined there
- Components: `CoreComponents` auto-imported (stat, badge, card, modal, table, etc.)
- Routes: `router.ex` — always check before writing tests
- Forms: `to_form(map)` without Ecto changesets
- CSV export: `push_event` + JS `CsvDownload` hook — MUST add `id` + `phx-hook="CsvDownload"` on element
- Dark mode: `ThemeToggle` JS hook in `assets/js/app.js`, persists to localStorage
- PubSub: Use `YellowDog.Console.PubSub` in console LiveViews (not `YellowDog.PubSub`)

## Important Gotchas

### Elixir / Erlang
- `DNS.Domain` and `DNS.ResourceRecordType` are structs — use `to_string/1` for comparisons and HEEx templates
- `:math.log2()` and `:math.ceil()` return **floats** — use `Kernel.ceil/1` for integer results
- `~w(\t)` produces literal `"\\t"` (two chars), NOT a tab — use `["\t"]` for non-printable chars
- `||` treats `false` and `0` as falsy — use `Map.has_key?/2` when falsy values are valid
- GenServers with SOME `handle_info` but no catch-all WILL crash; modules with NONE inherit default
- Umbrella child apps can't reference parent modules — use Application env for cross-app config
- `<<x::size(n)>>` requires integer `n` — use `:binary.decode_unsigned/1` for variable-length binaries

### LiveView / Phoenix
- `@foo` in HEEx templates = `socket.assigns.foo`, NOT module attributes — assign in `mount` if needed
- `connected?(@socket)` is deprecated in LiveView 1.0 — use assigns or conditional logic
- `if connected?(socket)` creates a new scope — `socket = assign(...)` inside doesn't rebind outer var; use `socket = if connected?(socket), do: assign(socket, ...), else: socket`
- Filter functions: expose as `def` (public) for unit testing from test files
- RecordForm is a `live_component` — events go through `phx-target={@myself}`, not parent LiveView
- Atom safety: use `@valid_list ~w(...)` + guard clause, not bare `String.to_existing_atom/1`

### IP / Network Formatting
- IP formatting: `:inet.ntoa/1` for tuple→charlist, `:inet.parse_address/1` for string→tuple
- IPv4/IPv6 integer conversion: use shared `Ipv4Util`/`Ipv6Util` modules (not private defp copies)
- DUID formatting: `DuidFormat.format!/2` returns "UNKNOWN" on failure (vs `format/2` → nil)

### Storage Patterns

- **Store (`YellowDog.Store.*`)**: unified backend for server-side apps — Concord (Raft KV, source of truth) with write-through ETS read cache. Domain facades: `Lease`, `Zone`, `Device`, `Rpz`, `Host`, `Cache`, `DynDns`, `Config`. GenStage `EventBridge` for cross-domain events
- **DNS zones**: managed via `YellowDog.Store.Zone`; `YellowDog.Dns.ZoneStore` is deprecated (kept for import/export compatibility)
- **DHCP leases (DHCPv4/v6)**: still direct Mnesia (`disc_copies`) in `LeaseStorage` — Store.Mnesia migration is planned but not done; tables have secondary indices by IP, state, and pool
- **DHCP client leases**: TOML file persistence via `LeaseStore` (netman product, no Store dependency)

### TOML Configuration Structure

Default config ships at `priv/yellowdogdns_default_config.toml`:
```toml
data_dir = "data"

[core]
dns = true
mdns = true
dhcpv4 = true
dhcpv6 = false
netboot = false

[dns]
# DNS server options

[[dhcpv4.pools]]
# Pool definitions (array-of-tables)

[dhcpv4.static_reservations]
"aa:bb:cc:dd:ee:ff" = "192.168.1.10"
```

Config loading/validation lives in `apps/yellow_dog_config/` (`YellowDog.Config`). Config changes trigger service reload via the Store's GenStage `ConfigWatcher` (hot-reload supported). Additional TOML configs in `config/`: `dhcp_acls.toml`, `dhcp_options.toml`, `dhcpv4_pools.toml`, `dhcpv6_pools.toml`.

## Test Environment

- DNS service disabled (avoids privileged port 53); Resolved also disabled in test
- E2E tests start with `port: 0` for auto-selection
- mDNS uses unicast to loopback in CI (no multicast)
- Property-based tests use `ExUnitProperties` (stream_data) — present in dhcp_client, ex_dhcp, and store
- Store tests run Concord in single-node mode — no external infra needed
- Console integration tests use `ConnCase`; config tests write temp TOML files to `System.tmp_dir!()`
- Test fixtures: `apps/yellow_dog_config/test/fixtures/*.toml` and `apps/yellow_dog/test/fixtures/*.toml` (valid_config, minimal_config, all_disabled, etc.)

## CI/CD

GitHub Actions workflows:
- **CI** (`ci.yml`): Matrix test on OTP 27+28, `--warnings-as-errors`, format check; Dialyzer **disabled** (GitHub runner OOM)
- **Docker** (`docker.yml`): Multi-arch Nix builds → GitHub Container Registry
- **Release** (`release.yml`): Automated releases
- Never disable any job in ci.yml

## Git Conventions

- Conventional commits: `feat|fix|refactor|test|docs|chore(scope): description`
- Omit "Generated with Claude Code" and Co-Authored-By trailer

## UI System

### Stack

Two dependencies only:
- `@duskmoon-dev/core` — TailwindCSS plugin (design tokens, utilities)
- `phoenix_duskmoon` — Phoenix component module (HEEx components)

`phoenix_duskmoon` wraps `duskmoon-elements` internally. Treat both as black boxes consumed via their published APIs only.

### Skills

Load before any UI task (via the Skill tool):
- CSS/tokens → `duskmoon-ui:duskmoon-dev-core`
- Web components → `duskmoon-ui:duskmoon-elements`
- Phoenix components → `elixir-dev:elixir-phoenix` + `duskmoon-ui:phoenix-duskmoon-ui`

Local project skill: `.claude/skills/abyss-udp-server.md` — read before working on Abyss-based UDP servers.

### Constraints

- NEVER vendor or replicate component internals
- NEVER override `@duskmoon-dev/core` tokens locally — propose changes upstream instead
- NEVER patch `phoenix_duskmoon` component logic inline — wrap or compose only
- Raw Tailwind classes not provided by `@duskmoon-dev/core` are PROHIBITED in templates

### Upstream Issue Protocol

When you encounter a bug, missing feature, or API gap:

1. Identify the correct repo:
   - Token/CSS/plugin issue → `duskmoon-dev/duskmoonui` (`@duskmoon-dev/core`)
   - Web component/element issue → `duskmoon-dev/duskmoon-elements`
   - Phoenix component issue → `duskmoon-dev/phoenix-duskmoon-ui`

2. Create a GitHub issue in that repo with:
   - Label: `internal request`
   - Expected vs actual behavior
   - Minimal reproduction

3. Add a comment at the workaround site: `# TODO: upstream duskmoon-dev/<repo>#<issue>`
   Do NOT silently absorb upstream bugs.
