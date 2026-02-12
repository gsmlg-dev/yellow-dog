# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Sub-App Context

When working on files within a specific sub-app (`apps/<app_name>/`), read that sub-app's `CLAUDE.md` if it exists:
```
apps/<app_name>/CLAUDE.md
```

## Project Overview

Yellow Dog is a distributed DNS/DHCP/mDNS server written in Elixir using an umbrella project structure. Elixir 1.18 / OTP 27-28, Phoenix LiveView 1.0, DaisyUI 5.0.

### Applications (10 total)

| App | Location | Purpose |
|-----|----------|---------|
| **YellowDog** | `apps/yellow_dog/` | Core: config management (TOML), orchestration, service manager |
| **YellowDog.Telemetry** | `apps/yellow_dog_telemetry/` | Centralized telemetry and span management |
| **YellowDog.Dns** | `apps/yellow_dog_dns/` | DNS server: views, zones, name resolution, ACLs |
| **YellowDog.Dhcpv4** | `apps/yellow_dog_dhcpv4/` | DHCPv4 server: lease management, address pools |
| **YellowDog.Dhcpv6** | `apps/yellow_dog_dhcpv6/` | DHCPv6 server: DUID-based leases, IA_NA support |
| **YellowDog.Mdns** | `apps/yellow_dog_mdns/` | mDNS responder: service discovery and registration |
| **YellowDogConsole** | `apps/yellow_dog_console/` | Phoenix LiveView web console (DaisyUI, Bun) |
| **abyss** | `apps/abyss/` | UDP server library (used by all protocol apps) |
| **ex_dns** | `apps/ex_dns/` | DNS protocol library (messages, zones, records) |
| **ex_dhcp** | `apps/ex_dhcp/` | DHCP protocol library (DHCPv4/v6 messages) |

Module naming: `YellowDog.<AppName>.ModuleName`. Infrastructure libs use own namespaces: `Abyss.*`, `DNS.*`, `DHCP.*`.

### Key Architecture Decisions

- Protocol apps are **library applications** started/managed by core `YellowDog.Application` — they have no `Application` modules
- Services are conditionally started via `YellowDog.Config.service_enabled?(:service_name)`
- Infrastructure libs (abyss, ex_dns, ex_dhcp) are **in-umbrella** with shared build paths
- All protocol servers follow the same pattern: `Server` (GenServer + Abyss) → `Handler` (Abyss.Handler behaviour) → `Supervisor` (conditional start)
- Configuration via TOML files loaded by `YellowDog.Config`

## Constitution (Architectural Constraints)

- **Do not use `:gen_udp` outside `apps/abyss/`** — All UDP socket operations (open, send, recv, close) must go through the Abyss abstraction layer (`Abyss.Client`, `Abyss.Transport.UDP`). Exempt: protocol libraries `ex_dns` and `ex_dhcp` which have no Abyss dependency by design

## Common Commands

```bash
# Run all tests (from umbrella root)
mix test

# Console tests specifically (MUST cd into app dir)
cd apps/yellow_dog_console && mix test

# Single test file
mix test apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/handler_test.exs

# E2E tests (auto-selects ports, CI-friendly)
mix test.e2e                # All E2E
mix test.e2e.dns            # DNS only

# Build verification (CI pipeline)
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict

# Start Phoenix console (dev)
cd apps/yellow_dog_console && mix phx.server    # http://localhost:4270

# Asset building
cd apps/yellow_dog_console
bun run build               # Dev (255KB + sourcemaps)
bun run build:prod          # Prod (136KB minified)

# Dev environment
direnv allow                # or: devenv shell
```

## Architecture

### Dependency Graph

```
YellowDog (core: config, orchestration)
├── YellowDog.Dns     → ex_dns + abyss + yellow_dog_telemetry
├── YellowDog.Dhcpv4  → ex_dhcp + abyss + yellow_dog_telemetry
├── YellowDog.Dhcpv6  → ex_dhcp + abyss + yellow_dog_telemetry
├── YellowDog.Mdns    → ex_dns + abyss + yellow_dog_telemetry
└── YellowDogConsole  → phoenix + all protocol apps (read-only status/stats)
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

## Test Environment

- DNS service disabled (avoids privileged port 53)
- DHCPv4 uses port 6767, DHCPv6 uses port 5667
- E2E tests start with `port: 0` for auto-selection
- mDNS uses unicast to loopback in CI (no multicast)

## CI/CD

GitHub Actions workflows:
- **CI** (`ci.yml`): Matrix test on OTP 27+28, `--warnings-as-errors`, format check
- **Docker** (`docker.yml`): Multi-arch Nix builds → GitHub Container Registry
- **Release** (`release.yml`): Automated releases
- Never disable any job in ci.yml

## Git Conventions

- Conventional commits: `feat|fix|refactor|test|docs|chore(scope): description`
- Omit "Generated with Claude Code" and Co-Authored-By trailer
