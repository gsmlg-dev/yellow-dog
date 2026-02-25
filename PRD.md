# Yellow Dog DHCP Client PRD

## Overview

A sovereign, protocol-aware DHCP client written entirely in Elixir/BEAM. Manages the full DHCPv4 lifecycle — from raw socket DORA handshake through OS-level address/route/DNS configuration — as a supervised OTP application.

**Umbrella App:** `yellow_dog_dhcp_client`
**Dependencies:** `ex_dhcp` (packet codec), OTP `:gen_statem`
**Not used:** `abyss` (DHCP client requires broadcast from `0.0.0.0` via platform-specific socket options)

### Core Motivations

- **Protocol Extensibility** — Handle non-standard Yellow Dog DHCP options (Vendor-Specific Information, Option 43/60) using Elixir binary pattern matching.
- **Operational Transparency** — Real-time telemetry and state monitoring of the network handshake via BEAM Telemetry and Phoenix LiveView integration.
- **NixOS Native Integration** — Replace imperative shell-scripted `dhcpcd` with a declarative, supervised GenStateMachine that fits into the NixOS systemd hierarchy.
- **Dual-Mode Flexibility** — Act as primary network owner in headless/server environments (Standalone) or as a specialized logic provider for NetworkManager-managed desktops (Hook).
- **Control Plane Bootstrap** — Use DHCP vendor options to exchange identity and discover a WebSocket control channel URL. The URL is extracted into the lease for future use by a control channel client (DNS updates, forced renewals, bandwidth reporting).

---

## Design Principles

- **Supervised** — Every component lives in a supervision tree with defined restart semantics.
- **Minimal Native Code** — The Rust NIF handles only socket operations and platform differences. All state, logic, and scheduling stays in Elixir.
- **No `:gen_udp` outside Abyss** — Per project constitution, all UDP socket operations go through the Rust NIF. `:gen_udp` is restricted to the Abyss app.
- **Declarative Configuration** — TOML config maps 1:1 to runtime behavior. No imperative setup scripts.
- **Telemetry First** — Every state transition, packet, and OS integration action emits telemetry events.
- **Crash-Friendly** — Interface flaps, socket crashes, and unexpected NAKs all resolve via supervisor restarts re-entering INIT.

---

## Supervision Tree

```
YellowDog.DHCPClient.Application
├── Registry (named: :dhcp_client_registry)
├── DynamicSupervisor (per-interface clients)
│   └── InterfaceSupervisor (one per interface, rest_for_one)
│       ├── DhcpSocket         — NIF resource owner, rx message router
│       ├── StateMachine       — :gen_statem FSM
│       ├── LeaseStore         — ETS-backed lease persistence
│       └── OSIntegration      — address/route/resolver management
└── ConfigWatcher              — watches TOML config, starts/stops interfaces
```

**Strategy: `rest_for_one`** — If DhcpSocket dies (NIF resource released on process death), StateMachine must restart (re-enters INIT). If StateMachine dies, LeaseStore survives for rebind on restart. If LeaseStore dies, OSIntegration restarts to re-sync state.

---

## Socket Strategy

### Problem

The BEAM has no native way to open a UDP broadcast socket with `SO_BINDTODEVICE` (Linux) or `IP_BOUND_IF` (FreeBSD) and send from `0.0.0.0:68` before IP assignment. Additionally, DAD requires sending raw ARP probes at L2, which no BEAM primitive supports.

### Insight: AF_PACKET Is Not Required

DHCP operates at L3 — the kernel special-cases UDP broadcast from `0.0.0.0:68 → 255.255.255.255:67` even before the interface has an IP. Standard UDP sockets with `SO_BROADCAST` work on both Linux and FreeBSD. AF_PACKET is Linux-only L2 access and is the wrong abstraction here.

The only exception is DAD (ARP probes), which genuinely requires raw socket / BPF access at L2.

### Solution: Rust NIF via Rustler

A small Rust NIF (~300 lines) that provides three capabilities:

1. **DHCP socket** — UDP broadcast socket bound to interface, `0.0.0.0:68`
2. **ARP socket** — Raw socket (Linux) or BPF (FreeBSD) for DAD probes
3. **Poll thread** — Background thread using epoll/kqueue that calls `enif_send()` to deliver received packets to the owning Elixir process

```
Elixir (BEAM schedulers)
┌─────────────────────────────────────────────────────┐
│  StateMachine ◄──── {:dhcp_rx, packet}              │
│       │                    ▲                        │
│       │ send/recv          │ enif_send()            │
│       ▼                    │                        │
│  DhcpSocket (GenServer)    │                        │
│       │                    │                        │
└───────┼────────────────────┼────────────────────────┘
        │ NIF calls          │
        ▼                    │
┌─────────────────────────────────────────────────────┐
│  Rust NIF (Dirty IO scheduler)                      │
│  ├── UDP socket (SO_BROADCAST + interface-bound)    │
│  ├── ARP socket (raw/BPF, for DAD only)             │
│  └── Poll thread → enif_send() on rx               │
└─────────────────────────────────────────────────────┘
        │
        ▼
    Linux / FreeBSD kernel
```

### Why Rust NIF Over Port Program

| Concern | Port Program | Rust NIF |
|---------|-------------|----------|
| Cross-platform | C + #ifdef or two binaries | `#[cfg(target_os)]` compile-time switch |
| Latency | stdin/stdout framing overhead | Direct binary passing, minimal overhead |
| Crash risk | Port crash is isolated | NIF crash kills BEAM |
| Mitigation | — | Well-tested, ~300 lines, Dirty IO only |
| Boot timing | Process spawn overhead | Already loaded |
| FreeBSD support | Needs separate BPF implementation | `socket2` + `nix` crates abstract this |

The NIF is small enough to audit and fuzz exhaustively. All NIF functions run on the Dirty IO scheduler — never on normal schedulers.

### NIF API

```rust
/// Open DHCP socket bound to interface, returns resource handle
#[rustler::nif(schedule = "DirtyIo")]
fn open(interface: String, owner_pid: LocalPid) -> Result<ResourceArc<DhcpSocket>, Error>

/// Send DHCP packet (UDP payload only, NIF wraps addressing)
#[rustler::nif(schedule = "DirtyIo")]  
fn send_broadcast(socket: ResourceArc<DhcpSocket>, packet: Binary) -> Result<Atom, Error>

/// Send unicast DHCP packet to specific server IP
#[rustler::nif(schedule = "DirtyIo")]
fn send_unicast(socket: ResourceArc<DhcpSocket>, dest_ip: (u8,u8,u8,u8), packet: Binary) -> Result<Atom, Error>

/// Send ARP probe for DAD (raw socket / BPF)
#[rustler::nif(schedule = "DirtyIo")]
fn send_arp_probe(socket: ResourceArc<DhcpSocket>, target_ip: (u8,u8,u8,u8)) -> Result<Atom, Error>

/// Close socket and stop poll thread
#[rustler::nif(schedule = "DirtyIo")]
fn close(socket: ResourceArc<DhcpSocket>) -> Atom
```

Received packets are delivered asynchronously via `enif_send()`:

```elixir
# DHCP packet received
{:dhcp_rx, packet_binary}

# ARP reply received (during DAD)
{:arp_rx, sender_ip, sender_mac}
```

### Cross-Platform Socket Implementation

```rust
#[cfg(target_os = "linux")]
mod linux {
    // UDP: AF_INET + SOCK_DGRAM + SO_BROADCAST + SO_BINDTODEVICE + IP_PKTINFO
    // ARP: AF_PACKET + SOCK_DGRAM + ETH_P_ARP
    // Poll: epoll
}

#[cfg(target_os = "freebsd")]
mod freebsd {
    // UDP: AF_INET + SOCK_DGRAM + SO_BROADCAST + IP_BOUND_IF + IP_RECVIF
    // ARP: BPF device (/dev/bpf)
    // Poll: kqueue
}
```

Critical socket options:

| Option | Linux | FreeBSD | Purpose |
|--------|-------|---------|---------|
| `SO_REUSEADDR` | ✅ | ✅ | Allow bind to port 68 |
| `SO_BROADCAST` | ✅ | ✅ | Enable broadcast send |
| Interface bind | `SO_BINDTODEVICE` | `IP_BOUND_IF` | Scope to interface |
| Packet info | `IP_PKTINFO` | `IP_RECVIF` | Identify receiving interface |
| Broadcast from 0.0.0.0 | `IP_FREEBIND` (if needed) | — | Kernel allows by default for DHCP |

### Rust Crate Dependencies

```toml
[dependencies]
rustler = "0.34"
socket2 = "0.5"
nix = { version = "0.29", features = ["net", "socket", "poll"] }
libc = "0.2"
```

No async runtime. No tokio. BEAM is the scheduler.

### Capabilities

On Linux, the BEAM process needs `CAP_NET_RAW` (for ARP socket) and `CAP_NET_ADMIN` (for Standalone mode address/route assignment). Set via systemd `AmbientCapabilities`.

On FreeBSD, the process needs access to `/dev/bpf` (typically via `devfs` rules or group membership) and appropriate privileges for interface configuration.

### Renewal Optimization

Once BOUND with a valid IP, RENEWING can use the NIF's `send_unicast()` to the DHCP server. The NIF socket remains open for REBINDING fallback (broadcast).

---

## Packet Layer

### Codec

Leverage `ex_dhcp` for standard DHCP message encode/decode. Thin wrapper module for Yellow Dog-specific concerns:

```elixir
defmodule YellowDog.DHCPClient.Packet do
  @moduledoc """
  DHCP packet construction and parsing with Yellow Dog vendor option support.
  Injects Option 60 (vendor class with version + capabilities) and Option 124 (PEN)
  in outbound packets. Decodes Option 125 (PEN-scoped vendor info) from replies.
  """

  @yellowdog_vendor_class "YellowDog"

  @doc "Build DHCPDISCOVER with Option 60 (vendor class), Option 124 (PEN), and Option 55 (parameter request list)."
  @spec build_discover(mac :: binary(), xid :: non_neg_integer(), keyword()) :: binary()

  @doc "Build DHCPREQUEST with Option 50 (requested IP), Option 54 (server ID), Option 60, and Option 124."
  @spec build_request(mac :: binary(), xid :: non_neg_integer(),
    server_ip :: :inet.ip4_address(), offered_ip :: :inet.ip4_address(), keyword()) :: binary()

  @doc "Build DHCPDECLINE for duplicate address detection failure."
  @spec build_decline(mac :: binary(), xid :: non_neg_integer(),
    server_ip :: :inet.ip4_address(), declined_ip :: :inet.ip4_address()) :: binary()

  @doc "Build DHCPRELEASE."
  @spec build_release(mac :: binary(), xid :: non_neg_integer(),
    server_ip :: :inet.ip4_address(), client_ip :: :inet.ip4_address()) :: binary()

  @doc """
  Parse reply packet into structured result.
  Extracts Option 125 sub-options when PEN matches Yellow Dog, populating
  control_url, auth_token, server_id, and cluster_id in the Lease struct.
  """
  @spec parse_reply(binary()) ::
    {:offer, Lease.t()} | {:ack, Lease.t()} | {:nak, String.t()} | {:error, term()}
end
```

### Vendor Identification Protocol

Yellow Dog uses IANA Private Enterprise Number (PEN) based vendor identification for mutual recognition between client and server. This follows RFC 3925 (Option 124/125) for clean namespacing alongside the simpler Option 60/43 fallback.

**PEN Registration:** Yellow Dog registers a PEN with IANA (free, takes ~2 weeks). The PEN is used as the enterprise number in Option 124/125.

```
PEN: {pending_registration}    # e.g., 99999 (placeholder)
Vendor Class: "YellowDog"
```

#### Client → Server Identification

The client announces itself in DHCPDISCOVER and DHCPREQUEST:

| Option | Name | Value | Purpose |
|--------|------|-------|---------|
| 60 | Vendor Class Identifier | `"YellowDog:1.0:{capabilities}"` | Simple identification + version |
| 124 | Vendor-Identifying Vendor Class | PEN + `"YellowDog"` | Formal PEN-scoped identification |
| 61 | Client Identifier | MAC or custom client ID | Unique client identity |
| 12 | Hostname | System hostname | Human-readable name |

**Option 60 format:** `YellowDog:{protocol_version}:{capability_flags}`

Capability flags (comma-separated):
- `dns` — Client runs Yellow Dog DNS service
- `dhcp-relay` — Client acts as DHCP relay
- `netboot` — Client provides netboot services
- `telemetry` — Client can report telemetry

Example: `"YellowDog:1.0:dns,telemetry"`

#### Server → Client Data (Option 125)

When the server recognizes a Yellow Dog client (via Option 60 or 124), it includes Option 125 (Vendor-Identifying Vendor-Specific Information) in DHCPOFFER and DHCPACK with the Yellow Dog PEN.

Option 125 encodes enterprise-scoped TLV sub-options:

```
Option 125 structure:
  Enterprise Number (4 bytes): {YellowDog PEN}
  Data Length (1 byte)
  Sub-options (TLV encoded):
    Sub-option code (1 byte)
    Length (1 byte)
    Value (variable)
```

#### Sub-Option Schema (v1)

| Code | Name | Type | Description |
|------|------|------|-------------|
| 1 | `control_url` | UTF-8 string | WebSocket control channel URL |
| 2 | `server_id` | UTF-8 string | Yellow Dog server identity |
| 3 | `cluster_id` | UTF-8 string | Cluster/site identifier |
| 4 | `auth_token` | UTF-8 string | One-time token for WebSocket auth |
| 5 | `control_url_fallback` | UTF-8 string | Fallback WebSocket URL |
| 6 | `flags` | uint16 | Server feature flags |
| 200-254 | Reserved | — | Future use |
| 255 | Padding | — | End marker |

**Critical sub-option:** `control_url` (code 1) contains the WebSocket endpoint that the client connects to after entering BOUND state. Example: `"wss://yd-server.local:4443/control/v1"`

The `auth_token` (code 4) is a short-lived nonce generated per-ACK. The client presents it during WebSocket handshake to prove it received a valid lease.

#### Vendor Options Module

```elixir
defmodule YellowDog.DHCPClient.VendorOptions do
  @moduledoc """
  Encode/decode Yellow Dog vendor options using PEN-scoped Option 124/125.
  Falls back to Option 60/43 for compatibility.
  """

  @yellowdog_pen 99999  # Placeholder — replace with registered PEN

  @spec encode_client_id(String.t(), [atom()]) :: binary()
  @doc "Encode Option 60 vendor class: YellowDog:{version}:{capabilities}"

  @spec encode_vendor_class(non_neg_integer()) :: binary()
  @doc "Encode Option 124 with Yellow Dog PEN."

  @spec decode_vendor_info(binary()) :: {:ok, map()} | {:error, term()}
  @doc "Decode Option 125 sub-options scoped to Yellow Dog PEN."

  @spec decode_sub_options(binary()) :: map()
  @doc "Parse TLV sub-options into named map with known codes resolved."
end
```

Application-specific sub-option codes are defined by the Yellow Dog DHCP server. Unknown codes are preserved as `{code, binary()}` tuples for forward compatibility.

---

## State Machine

`:gen_statem` with `handle_event_function` callback mode.

### States

```
INIT → SELECTING → REQUESTING → BOUND → RENEWING → REBINDING
  ↑                               ↑        │           │
  │                               │        T1          T2
  │                               └────────┘           │
  └────────────────────────────────────────────────────┘
```

### State Transitions

| From | Event | To | Action |
|------|-------|----|--------|
| INIT | entry | — | Send DHCPDISCOVER, start retransmit timer (exponential backoff: 2,4,8,16,32,64s + random jitter ±1s) |
| INIT | `{:rx, :offer, lease}` | SELECTING | Accumulate offer, start selection window timer |
| INIT | `:retransmit_timeout` | INIT | Resend DISCOVER with new XID |
| SELECTING | entry | — | Start selection window timer (default 1s) |
| SELECTING | `{:rx, :offer, lease}` | SELECTING | Accumulate offer |
| SELECTING | `:selection_timeout` | REQUESTING | Pick best offer per selection criteria |
| REQUESTING | entry | — | Send DHCPREQUEST (broadcast), start retransmit timer |
| REQUESTING | `{:rx, :ack, lease}` | BOUND | (via DAD check) |
| REQUESTING | `{:rx, :nak, _}` | INIT | Delay 1s before re-entering |
| REQUESTING | `:retransmit_timeout` | REQUESTING | Resend REQUEST (max 4 attempts, then → INIT) |
| BOUND | entry | — | Store lease, notify OSIntegration, schedule T1/T2 timers, emit telemetry |
| BOUND | `:t1_timeout` | RENEWING | — |
| BOUND | `:t2_timeout` | REBINDING | — |
| BOUND | `:release` | INIT | Send DHCPRELEASE, deconfigure |
| BOUND | `:interface_down` | INIT | Deconfigure |
| RENEWING | entry | — | Send unicast DHCPREQUEST to server (via NIF `send_unicast()`) |
| RENEWING | `{:rx, :ack, lease}` | BOUND | New lease |
| RENEWING | `{:rx, :nak, _}` | INIT | Deconfigure |
| RENEWING | `:t2_timeout` | REBINDING | — |
| RENEWING | `:retransmit_timeout` | RENEWING | Resend unicast REQUEST |
| REBINDING | entry | — | Send broadcast DHCPREQUEST (via raw socket) |
| REBINDING | `{:rx, :ack, lease}` | BOUND | New lease |
| REBINDING | `{:rx, :nak, _}` | INIT | Deconfigure |
| REBINDING | `:lease_expired` | INIT | Deconfigure |
| REBINDING | `:retransmit_timeout` | REBINDING | Resend broadcast REQUEST |

### Offer Selection Criteria

Priority order when multiple offers received during selection window:

1. Offer contains Yellow Dog PEN in Option 125 (confirmed YellowDog server with control channel)
2. Offer contains Yellow Dog vendor class match in Option 60 (YellowDog server, possibly older)
3. Offer from previously-known server (lease store has prior lease from this server)
4. First offer received (FIFO)

### Retransmission Timing

Per RFC 2131 §4.1:

- INIT/SELECTING: Exponential backoff starting at 2s, doubling to max 64s, with random jitter ±1s
- REQUESTING: 2s, 4s, 8s, 16s then back to INIT
- RENEWING/REBINDING: Half remaining time until next deadline (T2 or lease expiry)

### Duplicate Address Detection

After receiving ACK but before entering BOUND and configuring the interface:

1. Send 3 ARP probes via NIF `send_arp_probe()` for the offered IP (per RFC 5227)
2. Wait 2s total (probes at 0ms, 700ms, 1400ms)
3. No reply (no `{:arp_rx, _, _}` received) → proceed to BOUND
4. `{:arp_rx, _, _}` received → send DHCPDECLINE to server, wait 10s, re-enter INIT

---

## Lease Data

```elixir
defmodule YellowDog.DHCPClient.Lease do
  @type t :: %__MODULE__{
    ip: :inet.ip4_address(),
    subnet_mask: :inet.ip4_address(),
    router: :inet.ip4_address() | nil,
    dns_servers: [:inet.ip4_address()],
    server_ip: :inet.ip4_address(),
    server_mac: binary() | nil,
    lease_time: pos_integer(),
    t1: pos_integer(),
    t2: pos_integer(),
    domain_name: String.t() | nil,
    ntp_servers: [:inet.ip4_address()],
    mtu: pos_integer() | nil,
    vendor_options: map(),
    control_url: String.t() | nil,
    control_url_fallback: String.t() | nil,
    auth_token: String.t() | nil,
    server_id: String.t() | nil,
    cluster_id: String.t() | nil,
    yellowdog_server: boolean(),
    obtained_at: DateTime.t(),
    xid: non_neg_integer(),
    raw_options: map()
  }

  defstruct [
    :ip, :subnet_mask, :router, :server_ip, :server_mac,
    :lease_time, :t1, :t2, :domain_name, :mtu, :obtained_at, :xid,
    :control_url, :control_url_fallback, :auth_token, :server_id, :cluster_id,
    dns_servers: [],
    ntp_servers: [],
    vendor_options: %{},
    yellowdog_server: false,
    raw_options: %{}
  ]
end
```

### Lease Persistence

LeaseStore is a GenServer backed by ETS for fast reads and periodic flush to disk.

**Path:** `/var/lib/yellowdog/leases/{interface}.lease`

**Format:** TOML, using the same copy-validate-replace transactional write pattern used across YellowDog.

**Startup behavior:** If a valid, non-expired lease exists on disk, skip INIT and enter REBINDING to attempt reuse per RFC 2131 §3.2. If the lease is expired, discard and enter INIT.

---

## OS Integration

### Behaviour

```elixir
defmodule YellowDog.DHCPClient.OSIntegration do
  @callback apply_lease(interface :: String.t(), lease :: Lease.t()) :: :ok | {:error, term()}
  @callback deconfigure(interface :: String.t()) :: :ok | {:error, term()}
  @callback apply_routes(interface :: String.t(), lease :: Lease.t()) :: :ok | {:error, term()}
  @callback apply_dns(lease :: Lease.t()) :: :ok | {:error, term()}
end
```

### Mode A: Standalone

**Module:** `YellowDog.DHCPClient.OSIntegration.Standalone`

For headless/server NixOS environments where the DHCP client is the primary network owner.

**Initial implementation:** `System.cmd/3` with `ip` commands.

| Action | Command |
|--------|---------|
| Assign IP | `ip addr add {ip}/{prefix_len} dev {iface}` |
| Set link up | `ip link set {iface} up` |
| Add default route | `ip route add default via {router} dev {iface}` |
| Configure DNS | Write `/run/yellowdog/resolv.conf.{iface}`, invoke `resolvconf -a {iface}` |
| Set MTU | `ip link set {iface} mtu {mtu}` (if lease provides MTU) |
| Deconfigure | `ip addr del`, `ip route del`, `resolvconf -d {iface}` |

**Production target:** Netlink via port program or `gen_netlink` NIF. Deferred to a follow-up iteration.

**Requires:** `CAP_NET_ADMIN` on the BEAM process (or a privileged helper binary).

### Mode B: Hook

**Module:** `YellowDog.DHCPClient.OSIntegration.Hook`

For desktop environments where NetworkManager manages the interface.

| Action | Method |
|--------|--------|
| Report lease | D-Bus API (`org.freedesktop.NetworkManager`) or `nmcli` |
| Report lease (alt) | Write lease data to dispatcher script output |
| Deconfigure | Not performed — NM handles teardown |

The client performs the DHCP handshake but defers all IP/route/DNS assignment to the OS. It sends the final lease data back to NetworkManager, allowing the OS to maintain a unified view of the network.

### Mode Selection

Configured via TOML. No runtime auto-detection.

---

## Yellow Dog Control Channel (Future Feature — Design Reference)

> **Note:** This section documents the intended control channel design for reference by both client and server implementations. The WebSocket client, message handling, and bandwidth monitoring are **not implemented in this task**. Only the DHCP-level vendor option exchange (Option 124/125) is implemented — the `control_url` and `auth_token` are extracted into the Lease struct and made available for future use.

### Concept

When the DHCP server is a Yellow Dog server, it includes a WebSocket control channel URL in the lease (Option 125, sub-option 1). A future ControlChannel process will establish a persistent WebSocket connection to this URL after entering BOUND, enabling bi-directional management: DNS updates, forced renewals, bandwidth reporting, health checks.

The control channel is **optional** — if the lease comes from a non-YellowDog server (no Option 125 with matching PEN), the DHCP lifecycle is fully functional without it.

### Connection Lifecycle (Future)

```
BOUND (lease has control_url)
  │
  ▼
Connect WebSocket (wss://server:4443/control/v1)
  ├── Upgrade with auth_token in header: Authorization: Bearer {auth_token}
  ├── Include client identity: X-YD-Client-ID: {mac}, X-YD-Interface: {iface}
  │
  ▼
CONNECTED
  ├── Send: client_hello (capabilities, version, current config)
  ├── Receive: server_hello (accepted capabilities, server version)
  │
  ▼
ACTIVE (bidirectional message exchange)
  │
  ▼
LEASE EXPIRED / RELEASE / INTERFACE DOWN
  ├── Send: disconnect (reason)
  └── Close WebSocket
```

### Authentication (Future)

The `auth_token` from Option 125 sub-option 4 is a one-time nonce valid for a short window (~60s) after DHCPACK. The client presents it as a Bearer token during the WebSocket upgrade. After connection, the server may issue a long-lived `session_token` for reconnection.

### Message Protocol (Future)

JSON over WebSocket. Common envelope:

```json
{
  "type": "message_type",
  "id": "unique-message-id",
  "timestamp": "2025-01-01T00:00:00Z",
  "payload": {}
}
```

### Client → Server Messages (Future)

| Type | Payload | Description |
|------|---------|-------------|
| `client_hello` | `{version, capabilities, hostname, mac, interface, lease_xid}` | Initial handshake after connect |
| `bandwidth_report` | `{rx_bytes, tx_bytes, rx_rate, tx_rate, measured_at}` | Periodic bandwidth measurement |
| `health_report` | `{uptime, memory, services: [{name, status}]}` | Client health status |
| `dns_report` | `{queries_total, cache_hit_ratio, upstream_latency_ms}` | DNS service metrics (if capability) |
| `ack` | `{reply_to, status}` | Acknowledge server command |
| `error` | `{reply_to, code, message}` | Error response to server command |
| `disconnect` | `{reason}` | Graceful disconnect notification |

### Server → Client Messages (Future)

| Type | Payload | Description |
|------|---------|-------------|
| `server_hello` | `{version, accepted_capabilities, session_token}` | Handshake response |
| `update_nameservers` | `{servers: [ip], search_domains: [string]}` | Push DNS configuration change |
| `force_renew` | `{reason}` | Trigger immediate DHCP RENEWING |
| `update_config` | `{key, value}` | Push configuration parameter |
| `request_report` | `{report_type}` | Request immediate health/bandwidth/dns report |
| `set_report_interval` | `{report_type, interval_s}` | Change reporting frequency |
| `notify` | `{level, message, action?}` | Informational notification |
| `session_token` | `{token, expires_at}` | Long-lived reconnection token |
| `ping` | `{}` | Keepalive |

---

## Configuration

```toml
[dhcp_client]
interface = "eth0"
mode = "standalone"           # "standalone" | "hook"
vendor_class = "YellowDog"
selection_window_ms = 1000
dad_enabled = true
dad_probes = 3
dad_wait_ms = 2000

[dhcp_client.standalone]
manage_routes = true
manage_dns = true
dns_method = "resolvconf"     # "resolvconf" | "direct" | "systemd-resolved"

[dhcp_client.hook]
backend = "networkmanager"    # "networkmanager" | "systemd-networkd"
```

**Multiple interfaces:** Each interface gets its own `[dhcp_client.{name}]` section and its own InterfaceSupervisor instance.

---

## Telemetry Events

### State Transitions

```elixir
[:yellow_dog, :dhcp_client, :state, :change]
measurements: %{duration_in_state_ms: integer()}
metadata: %{interface: String.t(), from: atom(), to: atom()}
```

### Packet TX/RX

```elixir
[:yellow_dog, :dhcp_client, :packet, :tx]
metadata: %{interface: String.t(), type: :discover | :request | :release | :decline}

[:yellow_dog, :dhcp_client, :packet, :rx]
metadata: %{interface: String.t(), type: :offer | :ack | :nak, server: :inet.ip4_address()}
```

### Lease Lifecycle

```elixir
[:yellow_dog, :dhcp_client, :lease, :bound]
measurements: %{lease_time_s: integer(), handshake_duration_ms: integer()}
metadata: %{interface: String.t(), ip: String.t(), server: String.t()}

[:yellow_dog, :dhcp_client, :lease, :renewed]
measurements: %{lease_time_s: integer()}
metadata: %{interface: String.t(), ip: String.t()}

[:yellow_dog, :dhcp_client, :lease, :expired]
metadata: %{interface: String.t(), ip: String.t()}
```

### OS Integration

```elixir
[:yellow_dog, :dhcp_client, :os, :apply]
measurements: %{duration_ms: integer()}
metadata: %{interface: String.t(), action: :configure | :deconfigure, result: :ok | :error}
```

### DAD

```elixir
[:yellow_dog, :dhcp_client, :dad, :start]
metadata: %{interface: String.t(), ip: String.t()}

[:yellow_dog, :dhcp_client, :dad, :result]
metadata: %{interface: String.t(), ip: String.t(), conflict: boolean()}
```

---

## NixOS Integration

### Systemd Unit

```nix
systemd.services.yellowdog-dhcp-client = {
  description = "YellowDog DHCP Client";
  after = [ "network-pre.target" ];
  before = [ "network.target" ];
  wants = [ "network.target" ];

  serviceConfig = {
    Type = "notify";
    ExecStart = "${yellowdog}/bin/yellowdog_dhcp_client start";
    AmbientCapabilities = "CAP_NET_RAW CAP_NET_ADMIN";
    CapabilityBoundingSet = "CAP_NET_RAW CAP_NET_ADMIN";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ "/var/lib/yellowdog" "/run/yellowdog" ];
    PrivateTmp = true;
    Restart = "on-failure";
    RestartSec = "2s";
  };
};
```

### Rust NIF Compilation

The Rust NIF is compiled via Rustler during `mix compile`. The Nix derivation includes `rustc` and `cargo` as build inputs. The compiled `.so` / `.dylib` is bundled in `priv/native/`. Capabilities (`CAP_NET_RAW`, `CAP_NET_ADMIN`) are granted to the BEAM process via systemd `AmbientCapabilities`, not via `setcap` on the NIF.

### NixOS Module Options

```nix
networking.dhcpcd.enable = false;   # Disable system dhcpcd
services.yellowdog-dhcp-client = {
  enable = true;
  interfaces = {
    eth0 = {
      mode = "standalone";
      vendorClass = "YellowDog";
      manageDns = true;
      dnsMethod = "resolvconf";
    };
  };
};
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| DhcpSocket process dies | NIF resource released on process death → supervisor restarts InterfaceSupervisor (rest_for_one) → FSM re-enters INIT |
| Interface removed (hotplug) | Netlink/polling detects removal → FSM transitions to INIT → OSIntegration deconfigures |
| Interface returns | ConfigWatcher detects link → starts new InterfaceSupervisor |
| All offers rejected | Stay in SELECTING until timeout → fall back to any offer, or re-enter INIT with backoff |
| NAK during RENEWING | Deconfigure → INIT |
| Lease expires during app downtime | On startup detect expired lease → enter INIT (not REBINDING) |
| Duplicate address detected | Send DHCPDECLINE → wait 10s → re-enter INIT |
| BEAM OOM / crash | systemd `Restart=on-failure` restarts the service → LeaseStore loads persisted lease → attempt REBINDING |
| Config change (TOML) | ConfigWatcher detects change → gracefully stop affected InterfaceSupervisor → start new one with updated config |

---

## File Structure

```
apps/yellow_dog_dhcp_client/
├── lib/
│   ├── yellow_dog_dhcp_client.ex
│   └── yellow_dog_dhcp_client/
│       ├── application.ex
│       ├── config.ex
│       ├── config_watcher.ex
│       ├── interface_supervisor.ex
│       ├── state_machine.ex
│       ├── dhcp_socket.ex
│       ├── lease.ex
│       ├── lease_store.ex
│       ├── packet.ex
│       ├── vendor_options.ex
│       ├── dad.ex
│       ├── os_integration/
│       │   ├── behaviour.ex
│       │   ├── standalone.ex
│       │   └── hook_nm.ex
│       └── telemetry.ex
├── native/
│   └── dhcp_socket/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs          # NIF entry points
│           ├── socket.rs       # DhcpSocket resource
│           ├── poll.rs         # Poll thread (epoll/kqueue → enif_send)
│           ├── arp.rs          # ARP probe send/receive
│           ├── linux.rs        # Linux socket options
│           └── freebsd.rs      # FreeBSD socket options
├── test/
│   ├── state_machine_test.exs
│   ├── packet_test.exs
│   ├── vendor_options_test.exs
│   ├── lease_store_test.exs
│   └── integration/
│       └── handshake_test.exs
└── mix.exs
```

---

## Testing Strategy

### Unit Tests

- **State machine transitions** — Mock DhcpSocket (in-process, no actual socket). Inject packets as messages, assert state transitions and outbound packets.
- **Packet encode/decode** — Roundtrip via `ex_dhcp`. Verify Yellow Dog vendor option injection/extraction.
- **Vendor options** — Option 124/125 encode/decode with PEN scoping. Unknown sub-option preservation. Malformed TLV handling. Verify `control_url` and `auth_token` extraction into Lease struct.
- **Lease store** — Write/read/expiry logic. Transactional file safety.
- **Offer selection** — Multiple offers with varying vendor class, server history. Prioritize YellowDog-identified servers.
- **DAD** — Mock ARP responses, verify DECLINE sent on conflict.

### NIF Tests (Rust)

- Socket open/close lifecycle — no resource leaks.
- `send_broadcast()` on loopback interface.
- `send_arp_probe()` sends valid ARP packet (capture and verify).
- Poll thread delivers `{:dhcp_rx, _}` to owner process.
- NIF handles invalid interface name gracefully (returns error, no crash).
- NIF handles double-close gracefully.
- Fuzz: arbitrary binaries passed to `send_broadcast()` — must not crash BEAM.

### Property Tests

- Packet encode/decode roundtrip via StreamData.
- Vendor sub-option TLV encode/decode roundtrip with arbitrary payloads.
- Fuzz vendor option parsing with arbitrary binary payloads.
- Retransmission timer jitter stays within bounds.

### Integration Tests

- Mock DHCP server using `ex_dhcp` server-side code from YellowDog umbrella with Option 125 responses.
- Full DORA handshake on loopback with vendor identification exchange.
- Verify `control_url` and `auth_token` present in lease after ACK from YellowDog server.
- Verify lease from non-YellowDog server has `yellowdog_server: false` and nil control fields.
- Requires `CAP_NET_RAW` in CI or runs in a network namespace (`ip netns`).
- Run on both Linux and FreeBSD CI targets.

---

## Implementation Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Socket layer | Rust NIF via Rustler (Dirty IO) | Cross-platform Linux + FreeBSD, low latency, ~300 lines auditable |
| Socket type | UDP broadcast (`0.0.0.0:68`), not AF_PACKET | Kernel handles IP/UDP framing, portable — AF_PACKET is Linux-only L2 |
| ARP for DAD | Raw socket (Linux) / BPF (FreeBSD) in same NIF | Only L2 requirement, compile-time platform switch |
| OS integration (initial) | `ip` commands via `System.cmd` | Fast to implement, production Netlink is follow-up |
| State machine | `:gen_statem` `handle_event_function` | Maximum flexibility for complex transition logic |
| Lease persistence format | TOML | Consistent with rest of YellowDog config |
| Packet codec | `ex_dhcp` | Already a project dependency, standards-compliant |
| Renewal socket | NIF `send_unicast()` | All UDP goes through NIF per project constitution (no `:gen_udp` outside Abyss) |
| Vendor identification | PEN + Option 124/125 | Clean namespacing, forward-compatible, fallback to 60/43 |

---

## Out of Scope

- DHCPv6 / SLAAC (future `yellow_dog_netd`)
- WiFi management
- Static IP configuration
- VPN / tunnel management
- General interface lifecycle management
- Netlink-based OS integration (follow-up iteration)
- WebSocket control channel client implementation (future — design documented for reference)
- Control channel server-side implementation (belongs in `yellow_dog_dhcp` server app)
- Bandwidth monitoring and reporting (future, requires control channel)
- Firmware/software update delivery over control channel (future)

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `ex_dhcp` | DHCP packet encode/decode |
| `rustler` | Rust NIF bindings for Elixir |
| OTP `:gen_statem` | State machine |
| Rust: `socket2` | Cross-platform socket abstraction |
| Rust: `nix` | Linux/FreeBSD syscall bindings |
| Rust: `libc` | Low-level OS types |
| Rust toolchain (Nix) | NIF compilation |

No new Hex dependencies beyond `ex_dhcp` and `rustler`.

---

## Acceptance Criteria

- [ ] Full DORA handshake completes on a real interface
- [ ] Lease persistence survives process restart (REBINDING on reboot)
- [ ] Standalone mode configures IP, routes, and DNS via `ip` commands
- [ ] Hook mode reports lease to NetworkManager via `nmcli` or D-Bus
- [ ] Client sends Option 60 (`YellowDog:{version}:{capabilities}`) and Option 124 (PEN) in DISCOVER/REQUEST
- [ ] Client decodes Option 125 sub-options scoped to Yellow Dog PEN from OFFER/ACK
- [ ] `control_url`, `auth_token`, `server_id`, `cluster_id` extracted from Option 125 into Lease struct
- [ ] Lease `yellowdog_server` flag set to `true` when PEN matches, `false` otherwise
- [ ] Offer selection prioritizes offers containing Yellow Dog PEN (Option 125), then Option 60 match
- [ ] Lease from non-YellowDog server works normally with nil vendor fields
- [ ] DAD prevents duplicate address assignment, sends DECLINE on conflict
- [ ] T1/T2 renewal timers fire correctly, RENEWING uses NIF unicast
- [ ] No `:gen_udp` usage — all UDP operations go through Rust NIF (project constitution)
- [ ] Retransmission backoff follows RFC 2131 §4.1 timing with jitter
- [ ] Telemetry events emitted for all state transitions, packets, and OS actions
- [ ] Supervision tree recovers from socket crash, interface flap, and unexpected NAK
- [ ] NixOS module configures and starts the service declaratively
- [ ] Rust NIF compiles and loads on Linux and FreeBSD
- [ ] NIF UDP broadcast socket works before interface has IP
- [ ] NIF ARP probes work for DAD on both platforms
- [ ] NIF fuzz tests pass — arbitrary binary input does not crash BEAM
- [ ] Multiple interfaces supported via per-interface config sections
- [ ] Unit tests cover state machine, packet layer, vendor options, lease store, and offer selection
- [ ] Integration test completes full handshake with vendor option exchange against mock DHCP server
- [ ] IANA PEN registration submitted

---

*Version: 1.1.0*
*Elixir: >= 1.18*
*OTP: >= 27*