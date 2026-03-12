# YellowDog NetMan — CLAUDE.md

## Overview

Network manager application providing wired ethernet management with DHCP/static IP, desired-state reconciliation, per-interface connection FSMs, kernel netlink integration, and TOML profile management.

## Architecture

```
YellowDog.Netman.Supervisor (rest_for_one)
├── Registry (YellowDog.Netman.Registry)
├── Kernel.Supervisor (rest_for_one)
│   ├── Kernel.Netlink (Rust port GenServer)
│   ├── Kernel.LinkMonitor (ETS: :netman_links)
│   ├── Kernel.AddressManager (ETS: :netman_addresses)
│   ├── Kernel.RouteManager (ETS: :netman_routes)
│   ├── Kernel.RuleManager (ETS: :netman_rules)
│   └── Kernel.NeighborMonitor (ETS: :netman_neighbors)
├── EventBus (Registry-based PubSub)
├── ProfileStore (TOML profiles, file_system watcher)
├── Connection.Supervisor (DynamicSupervisor)
│   └── Connection.FSM (gen_statem per interface)
├── Connection.LeaseCoordinator (DHCP telemetry → FSM routing)
├── ReconciliationEngine (observe→diff→apply loop)
└── API.Supervisor
    └── API.CLI (Unix socket JSON-RPC)
```

## Key Patterns

- **Connection.FSM** uses `:gen_statem` with `:state_functions` — NOT GenServer
- **Kernel monitors** store state in named ETS tables for concurrent reads
- **EventBus** uses Registry with `:duplicate` keys for topic-based PubSub
- **ProfileStore** watches profile directory with `file_system` for hot-reload (200ms debounce)
- **ReconciliationEngine** debounces events (100ms), subscribes to link/profile/connection events; auto-deactivates orphaned FSMs when profiles are deleted; pushes updated profiles to running FSMs on hot-reload
- **Netlink backend** is configurable: `:mock` for tests, `:port` for production
- **LeaseCoordinator** bridges DHCP client telemetry events to FSM processes via Registry lookup

## Test Configuration

```elixir
# In test_helper.exs:
Application.put_env(:yellow_dog_netman, :netlink_backend, :mock)
Application.put_env(:yellow_dog_netman, :reconciliation_interval_ms, 60_000)
```

Use `MockNetlink` from `test/support/mock_netlink.ex` to simulate kernel events.

## Integration Points

- `YellowDog.DhcpClient.start_interface/2` — DHCP lease acquisition
- `YellowDog.DhcpClient.release/1` — lease release
- DHCP telemetry events: `[:yellow_dog, :dhcp_client, :lease, :bound|:renewed|:expired]` → LeaseCoordinator → FSM
- `YellowDog.Resolved.set_link_dns/2` / `reset_link_dns/1` — per-link DNS configuration

## Commands

```bash
cd apps/yellow_dog_netman && mix test     # 840+ tests + 2055 properties (~25 min)
cd apps/yellow_dog_netman && mix test --exclude property  # Unit/integration only (~2 min)
cd apps/yellow_dog_netman && mix credo --strict
```

## Testing Notes

- Property tests (21 files, 2055 properties) take ~25 minutes — use `--exclude property` for quick feedback
- `ReconciliationEngine.reconcile()` is async cast + debounce — in tests, use `send(ReconciliationEngine, :debounced_reconcile)` to bypass
- 203 Rust tests in `native/netlink_helper/` — run with `CARGO_TARGET_DIR=/tmp/... cargo test`
- Rust `target/` dir may be root-owned from Docker builds; use temp target dir for local runs
- **ProfileStore registration required**: Tests that start FSMs with `>100ms` sleeps MUST call `ProfileStore.put(profile_id, profile)` before starting the FSM — otherwise the background ReconciliationEngine will auto-deactivate the orphaned FSM during debounced reconciliation

## Profile Features

- DNS search domains: `ipv4.dns_search` / `ipv6.dns_search` in TOML profiles
- Search domains flow through DesiredState → FSM push_dns → Resolved (FSM is authoritative DNS source, not ReconciliationEngine)
- FSM `push_dns` merges profile DNS + DHCP lease DNS servers, parses strings to IP tuples
- Empty DNS server list triggers `reset_link_dns` to clear stale Resolved config

## IPv6 SLAAC Handling

- FSM `configure_ip` with `ipv4=disabled, ipv6=auto` waits for kernel SLAAC (netlink address event)
- `ip_check` only bypasses address verification when BOTH IPv4 and IPv6 are disabled/link-local
- `activated` state monitors global address removal for both IPv4 and IPv6 protocols
- In tests: mock netlink doesn't auto-populate ETS from `add_address` commands — must call `MockNetlink.address_added` to simulate kernel events

## Dual-Stack DHCP Late Arrival

- When `ipv4=auto, ipv6=auto`, IPv6 SLAAC may activate before DHCP completes
- FSM handles `dhcp_lease_acquired` in both `:ip_check` and `:activated` states
- Late lease stored in FSM data + DNS re-pushed to merge DHCP DNS with profile DNS

## Profile Hot-Reload

- ProfileStore watches TOML files (200ms debounce) → publishes `:reloaded` event; tracks path→ID mapping to clean up stale entries when profile ID changes
- ReconciliationEngine intercepts profile events and pushes new profile to FSM via `FSM.update_profile/2`
- Non-method changes (DNS, priority, MTU): applied in-place, DNS re-pushed
- IP method changes (e.g., auto→manual): FSM deactivates then re-activates with new config
- FSM `update_profile` handler exists in ALL states — caches profile immediately, method changes trigger reactivation in active states
