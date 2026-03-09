# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Sub-App Context

When working on files within a specific sub-app (`apps/<app_name>/`), read that sub-app's `CLAUDE.md` if it exists:
```
apps/<app_name>/CLAUDE.md
```

## Project Overview

Yellow Dog is a distributed DNS/DHCP/mDNS/Netboot server written in Elixir using an umbrella project structure. Elixir 1.18 / OTP 27-28, Phoenix LiveView 1.0, DaisyUI 5.0.

### Applications (17 total)

| App | Location | Purpose |
|-----|----------|---------|
| **YellowDog** | `apps/yellow_dog/` | Core: config management (TOML), orchestration, service manager |
| **YellowDog.Telemetry** | `apps/yellow_dog_telemetry/` | Centralized telemetry and span management |
| **YellowDog.Dns** | `apps/yellow_dog_dns/` | DNS server: views, zones, name resolution, ACLs |
| **YellowDog.Dhcpv4** | `apps/yellow_dog_dhcpv4/` | DHCPv4 server: lease management, address pools |
| **YellowDog.Dhcpv6** | `apps/yellow_dog_dhcpv6/` | DHCPv6 server: DUID-based leases, IA_NA support |
| **YellowDog.DhcpClient** | `apps/yellow_dog_dhcp_client/` | DHCPv4 client: DORA handshake, vendor options, NIF socket |
| **YellowDog.Mdns** | `apps/yellow_dog_mdns/` | mDNS responder: service discovery and registration |
| **YellowDog.Netboot** | `apps/yellow_dog_netboot/` | Network boot: TFTP server, iPXE scripts, device registry, HTTP boot |
| **YellowDog.Fingerprint** | `apps/yellow_dog_fingerprint/` | Passive DHCP fingerprinting for device identification |
| **YellowDog.Identity** | `apps/yellow_dog_identity/` | Host identity: registry, SSH key validation, trust verification, approval policies |
| **YellowDog.Netman** | `apps/yellow_dog_netman/` | Network manager: wired ethernet, DHCP/static IP, reconciliation engine, netlink |
| **YellowDog.Resolved** | `apps/yellow_dog_resolved/` | DNS stub resolver: intercept rules, cache, upstream forwarding, EDNS discovery |
| **YellowDogConsole** | `apps/yellow_dog_console/` | Phoenix LiveView web console (DaisyUI, Bun) |
| **GeoIpDb** | `apps/geo_ip_db/` | IP geolocation database library (MMDB format) |
| **Abyss** | `apps/abyss/` | UDP server library (used by all protocol apps) |
| **ExDns** | `apps/ex_dns/` | DNS protocol library (messages, zones, records) |
| **ExDhcp** | `apps/ex_dhcp/` | DHCP protocol library (DHCPv4/v6 messages) |

Module naming: `YellowDog.<AppName>.ModuleName`. Infrastructure libs use own namespaces: `Abyss.*`, `DNS.*`, `DHCP.*`, `GeoIpDb.*`.

### Key Architecture Decisions

- Protocol apps are **library applications** started/managed by core `YellowDog.Application` — they have no `Application` modules. **Exception:** `yellow_dog_resolved` has its own `Application` module because it is a standalone client-side stub resolver, not a server-side protocol handler
- Services are conditionally started via `YellowDog.Config.service_enabled?(:service_name)`
- Infrastructure libs (abyss, ex_dns, ex_dhcp) are **in-umbrella** with shared build paths
- All protocol servers follow the same pattern: `Server` (GenServer + Abyss) → `Handler` (Abyss.Handler behaviour) → `Supervisor` (conditional start)
- Configuration via TOML files loaded by `YellowDog.Config`
- **DhcpClient** uses swappable implementations via Application env: `socket_impl` (NIF in prod, `UdpFallback` in test) and `os_integration` (`Standalone` via `ip` commands, or `HookNM` for NetworkManager)

## Constitution (Architectural Constraints)

- **Do not use `:gen_udp` outside `apps/abyss/`** — All UDP socket operations (open, send, recv, close) must go through the Abyss abstraction layer (`Abyss.Client`, `Abyss.Transport.UDP`). Exempt: protocol libraries `ex_dns` and `ex_dhcp` which have no Abyss dependency by design. **Exception:** `DhcpSocket.UdpFallback` in `apps/yellow_dog_dhcp_client/` is a dev/test-only socket stub that uses `:gen_udp` because the DHCP client deliberately excludes Abyss (which cannot provide the broadcast-from-`0.0.0.0:68` socket semantics required by RFC 2131). In production the Rust NIF (`DhcpSocket.Native`) is always used; `UdpFallback` is never deployed.

## Common Commands

```bash
# Run all tests (from umbrella root)
mix test

# Console tests specifically (MUST cd into app dir)
cd apps/yellow_dog_console && mix test

# Single test file
mix test apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/handler_test.exs

# DHCP client tests
mix test apps/yellow_dog_dhcp_client/test/

# E2E tests (auto-selects ports, CI-friendly)
mix test.e2e                # All E2E
mix test.e2e.dns            # DNS only

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
bun run build               # Dev (255KB + sourcemaps)
bun run build:prod          # Prod (136KB minified)
# Note: Bun bundles JS; Tailwind CSS v4 runs as a standalone CLI (not via PostCSS)

# Pre-commit check (console only)
cd apps/yellow_dog_console && mix precommit     # compile + format + test

# Dev environment
direnv allow                # or: devenv shell
```

## Architecture

### Dependency Graph

```
YellowDog (core: config, orchestration)
├── YellowDog.Dns         → ex_dns + abyss + yellow_dog_telemetry
├── YellowDog.Dhcpv4      → ex_dhcp + abyss + yellow_dog_telemetry
├── YellowDog.Dhcpv6      → ex_dhcp + abyss + yellow_dog_telemetry
├── YellowDog.Mdns        → ex_dns + abyss + yellow_dog_telemetry
├── YellowDog.Netboot     → abyss + yellow_dog_telemetry
├── YellowDog.Fingerprint → ex_dhcp + yellow_dog_telemetry
├── YellowDog.DhcpClient  → ex_dhcp + yellow_dog_telemetry
├── YellowDog.Netman      → yellow_dog + yellow_dog_dhcp_client + yellow_dog_telemetry
├── YellowDog.Identity    → yellow_dog + yellow_dog_telemetry
└── YellowDogConsole      → phoenix + all service apps + geo_ip_db (read-only status/stats)
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
| System | Settings, Logs, Diagnostics, Process Map | TOML config persistence, process tree SVG |

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

- **DHCP leases (DHCPv4/v6)**: Mnesia with `disc_copies` — ACID-safe, persists across restarts; tables have secondary indices by IP, state, and pool
- **DNS zones**: ETS for high-concurrency in-memory access
- **DHCP client leases**: TOML file persistence via `LeaseStore`

### TOML Configuration Structure

Default config (`config/yellowdogdns_default_config.toml`):
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

Config changes trigger reload via `ConfigWatcher` (hot-reload supported).

## Test Environment

- DNS service disabled (avoids privileged port 53)
- DHCPv4 uses port 6767, DHCPv6 uses port 5667
- E2E tests start with `port: 0` for auto-selection
- mDNS uses unicast to loopback in CI (no multicast)
- Property-based tests use `ExUnitProperties` (stream_data) — present in dhcp_client and ex_dhcp
- Console integration tests use `ConnCase`; config tests write temp TOML files to `System.tmp_dir!()`
- Test fixtures: `apps/yellow_dog/test/fixtures/*.toml` (valid_config, minimal_config, all_disabled, etc.)

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

Load before any UI task:
- CSS/tokens → `.claude/skills/duskmoon-dev-core/SKILL.md`
- Web components → `.claude/skills/duskmoon-elements/SKILL.md`
- Phoenix components → `.claude/skills/elixir-phoenix/SKILL.md` + `.claude/skills/phoenix-duskmoon-ui/SKILL.md`

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
