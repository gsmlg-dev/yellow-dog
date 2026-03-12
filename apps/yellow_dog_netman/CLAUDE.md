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
- **ReconciliationEngine** debounces events (100ms), subscribes to link/profile/connection events; auto-deactivates orphaned FSMs when profiles are deleted
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
cd apps/yellow_dog_netman && mix test     # 771+ tests + 2055 properties (~25 min)
cd apps/yellow_dog_netman && mix test --exclude property  # Unit/integration only (~30s)
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
- Search domains flow through DesiredState → ReconciliationEngine DNS diffs → FSM push_dns → Resolved
