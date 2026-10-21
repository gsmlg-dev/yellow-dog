# CLAUDE.md — yellow_dog_dhcp_client

## Overview

Sovereign DHCPv4 client implementing the full DORA lifecycle as a supervised OTP application. Uses `:gen_statem` for the state machine, the optional upstream Abyss DHCP Rust NIF for platform-specific broadcast socket operations, and `ex_dhcp` for packet codec.

## Architecture

```
Application
├── Registry (:dhcp_client_registry)
├── DynamicSupervisor (per-interface clients)
│   └── InterfaceSupervisor (rest_for_one)
│       ├── DhcpSocket         — Socket wrapper (Abyss NIF in prod, gen_udp fallback)
│       ├── StateMachine       — :gen_statem FSM (INIT→SELECTING→REQUESTING→BOUND→RENEWING→REBINDING)
│       └── LeaseStore         — ETS + TOML disk persistence
└── ConfigWatcher              — Watches TOML config, reconciles interfaces
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `YellowDog.DhcpClient` | Public API facade |
| `StateMachine` | `:gen_statem` DHCP FSM with RFC 2131 retransmission |
| `Packet` | DHCP packet build/parse with Yellow Dog vendor options |
| `VendorOptions` | RFC 3925 Option 124/125 PEN-scoped encode/decode |
| `DhcpSocket` | Behaviour-based socket abstraction |
| `DhcpSocket.UdpFallback` | `:gen_udp` implementation for dev/test |
| `DAD` | Duplicate Address Detection (ARP probes, RFC 5227) |
| `LeaseStore` | ETS-backed with TOML disk flush |
| `OSIntegration.Standalone` | IP/route/DNS via `ip` commands |
| `OSIntegration.HookNM` | NetworkManager integration via `nmcli` |
| `Config` | TOML config parsing |
| `ConfigWatcher` | File watching + interface reconciliation |
| `Telemetry` | Event emission helpers |

## Testing

```bash
# All tests (from app directory)
cd apps/yellow_dog_dhcp_client && mix test

# Integration tests only
mix test test/integration/

# Specific test
mix test test/vendor_options_test.exs
```

- Socket impl is swappable via Application env `:socket_impl`
- Packet module is swappable via Application env `:packet_module`
- DAD is disabled in tests via `dad_enabled: false` config
- LeaseStore uses temp dirs in tests

The retained app is excluded from the default root build. Validate its production
socket path separately, from the repository root:

```bash
devenv shell -- python3 scripts/e2e/dhcp_client_native.py
```

This creates a fresh isolated consumer from the actual socket and adapter source,
resolves the production manifest's coordinated Hex versions, checks native loading
and socket contracts, builds and evaluates an explicit native consumer release,
and runs the upstream isolated DHCP/ARP packet and cleanup checks through the
YellowDog adapter. It prints the stage directory and writes `evidence.json` there.
Namespace setup requires passwordless sudo; inability to create the topology is
reported as `BLOCKED_ENV` after the other gates run. `--no-wire` explicitly marks
packet checks as unrun. These checks do not build a complete retained client
release or enable/deploy the client in the default products.

## Dependencies

- `ex_dhcp` (in-umbrella) — DHCP packet codec
- `abyss` (Hex `~> 0.9.0`) — UDP infrastructure and DHCP facade
- `abyss_raw` (Hex `~> 0.9.0`, production only) — Native DHCP/ARP socket implementation; not part of the supported DNS-only Worker
- `yellow_dog` (in-umbrella) — Core config
- `yellow_dog_telemetry` (in-umbrella) — Telemetry
- `telemetry`, `file_system`, `toml` (Hex)

## Gotchas

- `DhcpSocket.UdpFallback` cannot broadcast from `0.0.0.0:68` — use Rust NIF for production
- The production Rust NIF comes from Hex `abyss_raw` and needs a Rust toolchain to compile. Its native artifact belongs to `:abyss_raw`; the adapter keeps the core `Abyss.DhcpSocket.Native` facade and wraps its successful resource in `{:ok, resource}` for the client behaviour.
- Yellow Dog PEN is placeholder `99999` — replace after IANA registration
- `:gen_statem` `state_enter` events fire on every state transition — watch for side effects
- `select_best_offer/1` reverses the offers list since they accumulate in reverse order
