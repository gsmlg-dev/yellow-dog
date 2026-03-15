# Product: YellowDog NetMan — Core + Wired Networking (Phase 1)

## Overview

Build the foundational layer of `yellow_dog_netman`, a NetworkManager replacement implemented as an Elixir OTP application within the YellowDog umbrella. This phase delivers wired ethernet management with DHCP and static IP, a desired-state reconciliation engine, per-interface connection FSMs, kernel netlink integration via a Rust port helper, TOML profile management, and a CLI interface.

**This phase alone produces a usable `systemd-networkd` replacement for headless servers.**

## Architecture Reference

The full architecture design is in `yellow_dog_netman_architecture.md`. This PRD implements Phase 1 only. All types, supervision trees, and data models referenced here are defined in that document.

## Context

YellowDog is an Elixir umbrella application providing DNS, DHCP, mDNS, and network infrastructure services. The following sibling apps already exist and must be integrated:

- `yellow_dog` — Core config (TOML), shared types, application supervisor
- `yellow_dog_dhcp_client` — DHCPv4/v6 lease acquisition (has public API: `start_lease/2`, `release_lease/1`, `renew_lease/1`)
- `yellow_dog_resolved` — DNS stub resolver (has public API: `set_link_dns/2`, `reset_link_dns/1`)
- `yellow_dog_telemetry` — Centralized telemetry with span tracking and app filtering

## Tech Stack

- **Language**: Elixir (OTP 26+, Elixir 1.16+)
- **Rust**: Port helper for netlink (communicates via length-prefixed JSON over stdin/stdout)
- **Configuration**: TOML (via `toml_elixir`)
- **Build**: Mix umbrella app at `apps/yellow_dog_netman/`
- **Test**: ExUnit, property-based tests via `stream_data`
- **Platform**: Linux only (netlink is Linux-specific)

## Features

### 1. Kernel Subsystem (`Kernel.Supervisor`)

Netlink integration for observing and controlling kernel network state.

**Components:**

- **`Kernel.Netlink`** — GenServer owning the Rust port process. Receives kernel events (link/address/route changes), dispatches commands (add/remove addresses, routes, set link state). Protocol: 4-byte length prefix + JSON payload over stdin/stdout.
- **`Kernel.LinkMonitor`** — Subscribes to RTM_NEWLINK/RTM_DELLINK events. Maintains ETS table of current link state (interface name, index, carrier, MTU, MAC, kind). Publishes `netman:link:{interface}` events to EventBus.
- **`Kernel.AddressManager`** — Subscribes to RTM_NEWADDR/RTM_DELADDR. Maintains address table. Provides `add_address/3`, `remove_address/3` commands.
- **`Kernel.RouteManager`** — Subscribes to RTM_NEWROUTE/RTM_DELROUTE. Maintains route table. Provides `add_route/1`, `remove_route/1`. Handles metric-based default route ordering.
- **`Kernel.RuleManager`** — Policy routing rules (RTM_NEWRULE/RTM_DELRULE). Needed for connection priority routing.
- **`Kernel.NeighborMonitor`** — Read-only ARP/NDP observation (RTM_NEWNEIGH/RTM_DELNEIGH).

**Rust Port Helper (`native/netlink_helper/`):**

- Single Rust binary using `netlink-packet-route`, `netlink-sys` crates
- Subscribes to RTNLGRP_LINK, RTNLGRP_IPV4_IFADDR, RTNLGRP_IPV4_ROUTE, RTNLGRP_IPV6_IFADDR, RTNLGRP_IPV6_ROUTE, RTNLGRP_NEIGH multicast groups
- Events → Elixir: `{"type": "link_change", "interface": "eth0", "state": "up", "carrier": true, "mtu": 1500}`
- Commands ← Elixir: `{"cmd": "link_set", "interface": "eth0", "state": "up"}`, `{"cmd": "addr_add", "interface": "eth0", "address": "10.0.0.1/24"}`, etc.
- Statically compiled for portability (musl target)

### 2. EventBus (`NetMan.EventBus`)

Registry-based PubSub for internal communication between subsystems.

**Topics:**

```
netman:link:{interface}          # Link state changes
netman:address:{interface}       # Address changes
netman:route:{table}             # Route changes
netman:connection:{id}           # Connection FSM state changes
netman:policy:*                  # Policy decisions
netman:profile:*                 # Profile CRUD events
netman:reconciliation:*          # Reconciliation cycle events
```

**API:**

```elixir
EventBus.subscribe("netman:link:eth0")
EventBus.publish("netman:link:eth0", {:carrier, true})
EventBus.broadcast("netman:link:*", {:global_refresh})
```

Implementation uses `Registry` with `:duplicate` keys. Wildcard matching via prefix subscription.

### 3. ProfileStore (`NetMan.ProfileStore`)

TOML-based connection profile management with hot-reload.

**Directories:**

- System profiles: `/etc/yellowdog/netman/profiles/`
- Default config: `priv/default_config/netman.toml`

**Profile Structure (TOML):**

```toml
[connection]
id = "office-ethernet"
type = "ethernet"
interface = "eth0"
autoconnect = true
autoconnect_priority = 100
zone = "trusted"

[ethernet]
mtu = 1500

[ipv4]
method = "auto"  # "auto" (DHCP), "manual" (static), "disabled"
# For static:
# address = "192.168.1.100/24"
# gateway = "192.168.1.1"
# dns = ["192.168.1.1"]

[ipv6]
method = "auto"  # "auto" (SLAAC+DHCPv6), "manual", "disabled", "link-local"
```

**Features:**

- Parse and validate TOML profiles on startup
- `inotify`-based hot-reload (detect file changes → re-parse → publish `netman:profile:changed`)
- Profile CRUD API: `list/0`, `get/1`, `put/2`, `delete/1`
- Validation: required fields, type constraints, interface name format
- Profile matching: given an interface, find best matching profile by type + interface name/pattern

### 4. Connection FSM (`Connection.FSM`)

Per-interface state machine managing connection lifecycle.

**States (Phase 1 subset):**

```
:unavailable → :disconnected → :prepare → :configuring → :ip_check → :activated → :deactivating → :failed
```

Phase 1 skips `:need_auth`, `:connecting`, `:secondaries` (WiFi/VPN states). Ethernet goes straight from `:prepare` to `:configuring`.

**Transitions:**

| From | Event | To | Action |
|------|-------|----|--------|
| `:unavailable` | hardware detected | `:disconnected` | Register in registry |
| `:disconnected` | profile matched / user activate | `:prepare` | Begin activation |
| `:prepare` | link ready | `:configuring` | Start DHCP or apply static IP |
| `:configuring` | IP acquired | `:ip_check` | Run connectivity check (basic, no portal detection in Phase 1) |
| `:ip_check` | check passed | `:activated` | Install routes, push DNS, notify PolicyEngine |
| `:activated` | carrier lost | `:disconnected` | Release lease, remove routes |
| `:activated` | user deactivate | `:deactivating` | Begin teardown |
| `:deactivating` | cleanup done | `:disconnected` | Release lease, flush addresses |
| any | fatal error | `:failed` | Log error, emit telemetry |
| `:failed` | retry / user action | `:disconnected` | Reset state |

**Process Model:**

- Dynamic children under `Connection.Supervisor` (DynamicSupervisor)
- One FSM per discovered interface
- Registered via `{:via, Registry, {NetMan.Registry, {:connection, interface_name}}}`
- `gen_statem` with `:state_functions` callback mode

**Integration Points:**

- `:prepare` → `Kernel.LinkMonitor` — set MTU, bring link up
- `:configuring` (DHCP) → `YellowDog.DHCPClient.start_lease(interface, opts)`
- `:configuring` (static) → `Kernel.AddressManager.add_address(interface, addr, prefix)`
- `:activated` → `YellowDog.Resolved.set_link_dns(interface, dns_config)`
- `:activated` → `Kernel.RouteManager.add_route(route)`
- `:deactivating` → `YellowDog.DHCPClient.release_lease(interface)`
- `:deactivating` → `Kernel.AddressManager` flush, `Kernel.RouteManager` remove

### 5. PolicyEngine (`NetMan.PolicyEngine`)

Pure-function module (no GenServer in Phase 1) that determines connection priority and default route selection.

**Responsibilities:**

- Calculate effective priority for each active connection
- Determine which connection provides the default route
- Produce sorted DNS server list from all active connections

**Priority Calculation:**

```
effective_priority = base_priority (from profile) + type_default
```

Type defaults: ethernet = 100, wifi = 50, vpn = 30, cellular = 20.

Higher priority → lower route metric → preferred default route.

**API:**

```elixir
PolicyEngine.default_route(active_connections) :: {:ok, connection_id} | :none
PolicyEngine.route_metrics(active_connections) :: %{connection_id => metric}
PolicyEngine.dns_priority(active_connections) :: [dns_config]
```

### 6. ReconciliationEngine (`NetMan.ReconciliationEngine`)

Core loop: `observe() → diff(desired, observed) → plan(diffs) → apply(plan) → verify()`

**GenServer with periodic timer (default 30s) plus event-triggered reconciliation.**

**Triggers:**

1. Kernel event (link/address/route change via EventBus)
2. Profile change (via EventBus)
3. Policy decision (priority change)
4. Timer tick (periodic full reconciliation)
5. External command (CLI activation)

**Diff Types:**

```elixir
{:add_address, interface, address_config}
{:remove_address, interface, address_spec}
{:add_route, route_config}
{:remove_route, route_spec}
{:activate_connection, profile_id}
{:deactivate_connection, profile_id}
{:update_dns, dns_config}
```

**Properties:**

- Idempotent: applying the same desired state twice produces no diffs
- Convergent: system moves toward desired state on every cycle
- Debounced: rapid events coalesced (100ms debounce window)

### 7. CLI Interface (`ydnm`)

Escript or Mix task communicating via Unix domain socket to `API.CLI` GenServer.

**Phase 1 Commands:**

```
ydnm status                       # System overview: interfaces, active connections
ydnm device                       # List all network interfaces
ydnm device show <interface>      # Detailed interface info (state, addresses, routes)
ydnm connection                   # List all profiles
ydnm connection show <id>         # Profile details
ydnm connection up <id>           # Activate profile
ydnm connection down <id>         # Deactivate profile
ydnm connection add <file>        # Import TOML profile
ydnm connection delete <id>       # Remove profile
ydnm monitor                      # Live event stream (tail -f style)
```

**API.CLI:**

- GenServer accepting connections on Unix domain socket (`/run/yellowdog/netman.sock`)
- JSON-RPC over the socket (simple request/response)
- CLI binary sends JSON command, reads JSON response, formats for terminal

### 8. Telemetry

All operations emit telemetry via `yellow_dog_telemetry`.

**Events:**

```elixir
[:yellow_dog, :netman, :connection, :state_change]
metadata: %{interface: string, from: atom, to: atom, profile_id: string}

[:yellow_dog, :netman, :reconciliation, :start]
[:yellow_dog, :netman, :reconciliation, :stop]
measurements: %{duration_ms: integer, diffs_count: integer, applied_count: integer}

[:yellow_dog, :netman, :kernel, :link_change]
metadata: %{interface: string, state: atom, carrier: boolean}

[:yellow_dog, :netman, :kernel, :address_change]
metadata: %{interface: string, action: :add | :remove, address: string}

[:yellow_dog, :netman, :kernel, :route_change]
metadata: %{action: :add | :remove, destination: string, gateway: string}

[:yellow_dog, :netman, :policy, :default_route_change]
metadata: %{old: string | nil, new: string, reason: atom}
```

## File Structure

```
apps/yellow_dog_netman/
├── lib/
│   ├── yellow_dog_netman.ex                 # Public API facade
│   ├── netman/
│   │   ├── application.ex                   # OTP Application
│   │   ├── supervisor.ex                    # Top-level rest_for_one supervisor
│   │   │
│   │   ├── kernel/
│   │   │   ├── supervisor.ex
│   │   │   ├── netlink.ex                   # Rust port GenServer
│   │   │   ├── link_monitor.ex
│   │   │   ├── address_manager.ex
│   │   │   ├── route_manager.ex
│   │   │   ├── rule_manager.ex
│   │   │   └── neighbor_monitor.ex
│   │   │
│   │   ├── connection/
│   │   │   ├── supervisor.ex                # DynamicSupervisor
│   │   │   ├── fsm.ex                       # gen_statem
│   │   │   └── ethernet.ex                  # Ethernet-specific activation logic
│   │   │
│   │   ├── event_bus.ex                     # Registry PubSub
│   │   ├── profile_store.ex                 # TOML profile management
│   │   ├── secret_store.ex                  # Stub (File backend Phase 1)
│   │   ├── policy_engine.ex                 # Priority calculation
│   │   ├── reconciliation_engine.ex         # Diff + apply loop
│   │   │
│   │   ├── api/
│   │   │   ├── supervisor.ex
│   │   │   └── cli.ex                       # Unix socket JSON-RPC
│   │   │
│   │   └── types/
│   │       ├── desired_state.ex
│   │       ├── observed_state.ex
│   │       ├── profile.ex
│   │       └── diff.ex
│   │
│   └── mix/
│       └── tasks/
│           └── compile/
│               └── rust_ports.ex             # Mix task to build Rust helper
│
├── native/
│   └── netlink_helper/
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs
│           ├── netlink.rs                    # Netlink socket + multicast
│           ├── protocol.rs                   # JSON encode/decode
│           └── commands.rs                   # RTM_* command execution
│
├── priv/
│   └── default_config/
│       └── netman.toml
│
├── test/
│   ├── test_helper.exs
│   ├── kernel/
│   │   ├── link_monitor_test.exs
│   │   ├── address_manager_test.exs
│   │   └── route_manager_test.exs
│   ├── connection/
│   │   └── fsm_test.exs
│   ├── policy/
│   │   └── policy_engine_test.exs
│   ├── reconciliation/
│   │   └── reconciliation_engine_test.exs
│   ├── profile_store_test.exs
│   ├── event_bus_test.exs
│   └── support/
│       ├── mock_netlink.ex                   # Simulated kernel events
│       └── test_profiles/                    # Sample TOML profiles
│           ├── static_ethernet.toml
│           └── dhcp_ethernet.toml
│
└── mix.exs
```

## Startup Sequence

```
1. Application.start/2
2. NetMan.Supervisor (rest_for_one) starts children in order:
   a. Kernel.Supervisor
      ├── Kernel.Netlink (opens Rust port, connects to netlink)
      ├── Kernel.LinkMonitor (queries existing links)
      ├── Kernel.AddressManager (queries existing addresses)
      ├── Kernel.RouteManager (queries existing routes)
      ├── Kernel.RuleManager
      └── Kernel.NeighborMonitor
   b. EventBus (Registry created)
   c. ProfileStore (reads TOML from disk, starts inotify watcher)
   d. SecretStore (stub)
   e. Connection.Supervisor (DynamicSupervisor, empty)
   f. PolicyEngine (if GenServer; or just a module)
   g. ReconciliationEngine
      → Runs initial reconciliation:
        - Reads observed state from Kernel.*
        - Reads desired state from ProfileStore
        - Matches profiles to discovered interfaces
        - Spawns Connection.FSM children for each match
        - FSMs begin activation
   h. API.Supervisor
      └── API.CLI (opens Unix socket)
```

## Integration Contracts

### yellow_dog_dhcp_client (existing app)

NetMan calls:
```elixir
YellowDog.DHCPClient.start_lease("eth0", [])
YellowDog.DHCPClient.release_lease("eth0")
```

NetMan subscribes to telemetry:
```elixir
[:yellow_dog, :dhcp_client, :lease, :acquired]   # → IP available
[:yellow_dog, :dhcp_client, :lease, :renewed]     # → IP still valid
[:yellow_dog, :dhcp_client, :lease, :expired]     # → IP lost
[:yellow_dog, :dhcp_client, :lease, :failed]      # → No lease obtained
```

### yellow_dog_resolved (existing app)

NetMan calls:
```elixir
YellowDog.Resolved.set_link_dns("eth0", %{
  servers: [{192, 168, 1, 1}],
  search: ["corp.example.com"],
  priority: 100
})
YellowDog.Resolved.reset_link_dns("eth0")
```

### yellow_dog_telemetry (existing app)

Use `YellowDog.Telemetry` macros for all event emission. Follow existing app-prefixed patterns.

## Acceptance Criteria

### Functional

- [ ] Detects ethernet interfaces via netlink and creates Connection.FSM processes
- [ ] Activates matching profiles automatically when `autoconnect = true`
- [ ] Obtains DHCP lease via `yellow_dog_dhcp_client` integration
- [ ] Applies static IP configuration from TOML profile
- [ ] Installs default route with correct metric based on connection priority
- [ ] Pushes per-link DNS configuration to `yellow_dog_resolved`
- [ ] Handles carrier loss gracefully (deactivate → wait → re-activate on carrier return)
- [ ] Hot-reloads profiles when TOML files change on disk
- [ ] Reconciliation engine is idempotent (same desired state → no diffs)
- [ ] Reconciliation engine converges after kernel state drift
- [ ] Multiple ethernet interfaces work simultaneously with correct priority ordering
- [ ] CLI `ydnm status` shows current state accurately
- [ ] CLI `ydnm connection up/down` activates/deactivates connections
- [ ] All state changes emit telemetry events
- [ ] Graceful shutdown: release leases, flush addresses, close netlink

### Non-Functional

- [ ] Reconciliation cycle completes in < 100ms for typical 2-interface setup
- [ ] Netlink event processing latency < 10ms (event received → EventBus published)
- [ ] Zero-downtime profile hot-reload (no connection interruption)
- [ ] Rust port helper compiles as static binary (musl) for NixOS/FreeBSD portability
- [ ] All GenServers supervised with restart strategies
- [ ] No kernel state mutations outside Kernel.* modules

## Testing Requirements

### Unit Tests

- PolicyEngine: priority calculation, default route selection, DNS ordering
- Diff algorithm: given desired + observed → expected diffs
- Profile parsing: valid TOML → struct, invalid TOML → error
- FSM transitions: state × event → next state (table-driven)

### Integration Tests (with mock netlink)

- Full lifecycle: interface detected → profile matched → DHCP → activated → carrier lost → deactivated
- Static IP lifecycle: profile with manual IP → activated → routes correct
- Multi-interface: two ethernet interfaces, correct priority ordering
- Profile hot-reload: modify TOML file → connection re-evaluated
- Reconciliation idempotency: run twice with same state → zero diffs second time

### Property-Based Tests

- Reconciliation idempotency: `∀ desired, observed: apply(diff(desired, observed)) → diff(desired, observed') = []`
- Profile round-trip: `∀ profile: parse(serialize(profile)) == profile`
- FSM reachability: all states reachable from initial, no deadlocks

### Mock Strategy

- `MockNetlink` module simulates kernel events (link up/down, address add/remove)
- DHCP client integration tested via telemetry events (mock the telemetry handler)
- Resolved integration tested via mock module or `:meck`

## Configuration

### Global Config (`priv/default_config/netman.toml`)

```toml
[netman]
reconciliation_interval_ms = 30000
reconciliation_debounce_ms = 100
profile_dir = "/etc/yellowdog/netman/profiles"
socket_path = "/run/yellowdog/netman.sock"

[netman.logging]
level = "info"

[netman.kernel]
netlink_helper_path = "priv/native/netlink_helper"
```

### mix.exs Dependencies

```elixir
defp deps do
  [
    {:yellow_dog, in_umbrella: true},
    {:yellow_dog_dhcp_client, in_umbrella: true},
    {:yellow_dog_resolved, in_umbrella: true},
    {:yellow_dog_telemetry, in_umbrella: true},
    {:toml_elixir, "~> 0.3"},
    {:file_system, "~> 1.0"},    # inotify for profile hot-reload
    {:stream_data, "~> 1.0", only: [:test]},
  ]
end
```

## Out of Scope (Future Phases)

- WiFi (Phase 2) — wpa_supplicant integration, scanning, MAC randomization
- Enterprise WiFi / 802.1X (Phase 3)
- Bond, Bridge, VLAN, PPPoE (Phase 4)
- VPN framework (Phase 5)
- Firewall / nftables (Phase 6)
- D-Bus compatibility (Phase 7)
- Captive portal, suspend/resume, rfkill (Phase 8)
- Fleet management via Phoenix Channel (Phase 9)
- Cellular / ModemManager (Phase 10)

## Implementation Notes

### Elixir Patterns

- Use `gen_statem` with `:state_functions` for Connection.FSM (not GenServer + manual state)
- Use `Registry` for process discovery and EventBus (not `pg` or global)
- Use `DynamicSupervisor` for Connection.Supervisor (interfaces come and go)
- All public API functions go through `YellowDog.NetMan` facade module
- Structs for all data types (DesiredState, ObservedState, Profile, Diff)
- Pattern match on telemetry events from sibling apps (no polling)

### Rust Port Patterns

- Port protocol: `{:spawn_executable, path}` with `[:binary, {:packet, 4}]`
- JSON encode/decode in both Rust and Elixir
- Rust binary handles netlink socket lifecycle, reconnects on error
- Events streamed as JSON lines, one per netlink message
- Commands are request-only (no response correlation needed for Phase 1)

### Error Handling

- Netlink port crash → Kernel.Supervisor restarts it → re-observe kernel state
- DHCP failure → FSM stays in `:configuring` with exponential backoff retry
- Profile parse error → log warning, skip invalid profile, continue with valid ones
- Reconciliation error → log, skip failed diff, attempt remaining diffs