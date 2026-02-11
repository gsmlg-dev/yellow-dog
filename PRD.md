# YellowDog Netboot PRD

## Overview

`yellow_dog_netboot` is a new umbrella app providing integrated network boot provisioning — TFTP server, HTTP boot endpoints, dynamic iPXE script generation, device registry, and install manifest API. Paired with `yellow_dog_dhcp` for boot option injection and `yellow_dog_console` for LiveView management UI.

**Umbrella app**: `apps/yellow_dog_netboot/`
**Module namespace**: `YellowDog.Netboot`
**Dependencies**: `yellow_dog` (core config), `yellow_dog_telemetry`, `abyss` (UDP transport for TFTP)

---

## Architecture

```
yellowdog/apps/
├── yellow_dog/                 # Core config, orchestration
├── yellow_dog_netboot/         # ← NEW: TFTP + netboot engine
├── yellow_dog_dhcp/            # Boot option injection (opt 66/67)
├── yellow_dog_console/         # LiveView UI (new netboot pages)
├── yellow_dog_dns/
├── yellow_dog_telemetry/
└── ...
```

### Supervision Tree

```
YellowDog.Netboot.Supervisor
├── TFTP.Server                 # UDP listener on :69, read-only RRQ
├── TFTP.TransferSupervisor     # DynamicSupervisor for active transfers
├── Device.Registry             # ETS-backed device state machine
├── Manifest.Store              # Profile/manifest config from TOML
├── Boot.ScriptEngine           # iPXE script template rendering
└── Asset.Store                 # Boot asset file index (kernels, initrds, iPXE binaries)
```

### Inter-App Communication

```
yellow_dog_dhcp ──→ YellowDog.Netboot.BootProfile.for_device/1
                    (query boot config during OFFER/ACK construction)

yellow_dog_netboot ──→ YellowDog.DHCP.Leases.lookup/1
                       (correlate device discovery from lease data)

yellow_dog_console ──→ YellowDog.Netboot.Device.Registry
                       YellowDog.Netboot.Manifest.Store
                       YellowDog.Netboot.TFTP.Server
                       (LiveView reads state, pushes config changes)
```

No circular deps — DHCP calls into Netboot, Netboot reads from DHCP, Console reads/writes to Netboot.

---

## Component Specifications

### 1. TFTP Server

Pure Elixir implementation of RFC 1350 (read-only).

**Scope**: Serve static boot assets — iPXE binaries, kernels, initrds. Read-only (RRQ only, reject WRQ/delete).

**Protocol**:
- UDP port 69 (configurable)
- RRQ → open ephemeral port per transfer → 512-byte DATA blocks → ACK-based flow control
- Support `blksize` option (RFC 2348) for larger blocks (1468 typical for ethernet MTU)
- Support `tsize` option (RFC 2349) for transfer size reporting

**Process model**:
- Listener GenServer on port 69 accepts RRQ, spawns transfer worker under `TransferSupervisor`
- Each transfer is a short-lived process with its own ephemeral UDP socket
- Transfer timeout: 30s idle, 5 retries per block

**File serving**:
- Configurable root directory (e.g., `/srv/netboot/tftp/`)
- Path traversal prevention (reject `..`, absolute paths)
- File index cached in ETS, invalidated on filesystem watch or manual reload

**Telemetry**:
```elixir
[:yellow_dog, :netboot, :tftp, :request]    # RRQ received
[:yellow_dog, :netboot, :tftp, :transfer]   # transfer complete/failed
[:yellow_dog, :netboot, :tftp, :error]      # protocol errors
```

### 2. HTTP Boot Endpoint

Phoenix routes in `yellow_dog_console` (or standalone Plug if console not running).

**Endpoints**:

| Route | Purpose |
|-------|---------|
| `GET /boot/ipxe` | Dynamic iPXE script (query params: mac, arch, uuid) |
| `GET /boot/assets/:path` | Static boot asset serving (kernel, initrd, images) |
| `GET /boot/manifest/:device_id` | Install manifest JSON for installer |
| `POST /boot/register` | Device self-registration from installer environment |
| `POST /boot/status` | Device install status callback |

**iPXE script generation** (`/boot/ipxe`):
- Input: `?mac=AA:BB:CC:DD:EE:FF&arch=x86_64&uuid=...`
- Lookup device in registry → match to boot profile
- Render iPXE script from template with profile-specific kernel/initrd/args
- Fallback: default profile or rescue shell

### 3. Device Registry

ETS-backed state machine with persistence to TOML.

**Device record**:
```elixir
%Device{
  mac: "AA:BB:CC:DD:EE:FF",
  uuid: nil | String.t(),
  hostname: nil | String.t(),
  arch: :x86_64 | :aarch64 | :bios_x86,
  profile_id: String.t(),
  state: :discovered | :booting | :installing | :installed | :failed | :reinstall_requested,
  ip_address: nil | :inet.ip_address(),
  hardware_info: map(),          # populated by installer registration
  first_seen: DateTime.t(),
  last_seen: DateTime.t(),
  install_attempts: integer(),
  last_error: nil | String.t(),
  tags: [String.t()],
  slot: %{active: :a | :b, pending: nil | :a | :b}  # future A/B
}
```

**State transitions**:
```
discovered ──→ booting ──→ installing ──→ installed
    ↑              │            │              │
    │              └──→ failed ←┘              │
    │                     │                    │
    └─────────────────────┘                    │
                                               ↓
                                    reinstall_requested ──→ booting
```

**API**:
```elixir
Device.Registry.register(mac, attrs)
Device.Registry.update_state(mac, new_state, metadata \\ %{})
Device.Registry.get(mac)
Device.Registry.list(filters \\ [])
Device.Registry.assign_profile(mac, profile_id)
Device.Registry.request_reinstall(mac)
```

**PubSub**: Broadcasts state changes on `"netboot:devices"` topic for LiveView updates.

### 4. Boot Profile / Manifest Store

TOML-based configuration for boot profiles and install manifests.

**Config structure** (`priv/netboot.toml` or global yellowdog config):

```toml
[netboot]
tftp_root = "/srv/netboot/tftp"
tftp_port = 69
default_profile = "nixos-minimal"

[netboot.profiles.nixos-minimal]
description = "NixOS Minimal Install"
kernel = "nixos/bzImage"
initrd = "nixos/initrd.img"
kernel_args = "init=/nix/store/...-init ip=dhcp"
installer_image = "nixos/installer.squashfs"
arch = ["x86_64"]

[netboot.profiles.nixos-desktop]
description = "NixOS Desktop (Flake)"
kernel = "nixos/bzImage"
initrd = "nixos/initrd.img"
kernel_args = "init=/nix/store/...-init ip=dhcp"
installer_image = "nixos/installer.squashfs"
arch = ["x86_64"]

[netboot.profiles.nixos-desktop.manifest]
profile = "nixos-desktop"
disk_layout = "single-root-btrfs"
flake = "github:user/system#x86_64-linux"
slot_strategy = "single"
post_install_hooks = []

[netboot.profiles.rescue]
description = "Rescue Shell"
kernel = "rescue/vmlinuz"
initrd = "rescue/initrd.img"
kernel_args = "rescue shell"
arch = ["x86_64", "aarch64"]
```

**API**:
```elixir
Manifest.Store.get_profile(profile_id)
Manifest.Store.list_profiles()
Manifest.Store.get_manifest(profile_id)
Manifest.Store.reload()                     # hot-reload from TOML
```

### 5. DHCP Integration

`yellow_dog_dhcp` must inject PXE boot options based on client architecture.

**Boot option injection logic** (called during OFFER/ACK construction):

```elixir
# In yellow_dog_dhcp worker, during response building:
case YellowDog.Netboot.BootProfile.for_device(client_mac, client_arch) do
  {:ok, %{boot_mode: :tftp, filename: filename, server: server}} ->
    # Set Option 66 (TFTP server) + Option 67 (boot filename)
    add_options(response, [{66, server}, {67, filename}])

  {:ok, %{boot_mode: :http, url: url}} ->
    # UEFI HTTP Boot - set vendor option with boot URL
    add_options(response, [{67, url}])

  :no_boot ->
    # Not a netboot device, skip
    response
end
```

**Architecture detection** from DHCP Option 60 / Option 93:

| Client Arch (Opt 93) | Type | Boot File |
|----------------------|------|-----------|
| 0x0000 | BIOS x86 | `undionly.kpxe` |
| 0x0006 | UEFI x86 | `ipxe.efi` |
| 0x0007 | UEFI x64 | `ipxe.efi` |
| 0x0009 | UEFI x64 | `ipxe.efi` |
| 0x000B | UEFI ARM64 | `ipxe-arm64.efi` |

### 6. iPXE Script Engine

Template-based dynamic iPXE script generation.

**Default template**:
```
#!ipxe
echo YellowDog Netboot - ${mac} (${arch})
dhcp
set base-url http://${yellowdog_ip}:${port}/boot/assets

kernel ${base-url}/${kernel} ${kernel_args} yellowdog.mac=${mac} yellowdog.api=http://${yellowdog_ip}:${port}
initrd ${base-url}/${initrd}
boot
```

**Conditional logic support**:
- Per-device overrides (rescue mode, reinstall flag)
- Profile-based kernel/initrd selection
- Architecture-specific boot paths
- Fallback chain on boot failure

---

## Console UI (LiveView)

All netboot management integrated into `yellow_dog_console` under `/netboot/*` routes.

### Navigation

Add "Netboot" section to main sidebar:
```
Netboot
├── Dashboard         /netboot
├── Devices           /netboot/devices
├── Boot Profiles     /netboot/profiles
├── TFTP Server       /netboot/tftp
└── Boot Log          /netboot/log
```

### Pages

#### Dashboard (`/netboot`)

Overview cards:
- **Device summary**: count by state (discovered / booting / installing / installed / failed)
- **TFTP status**: running/stopped, port, total transfers today
- **Active transfers**: list of in-progress TFTP transfers
- **Recent activity**: last 10 state transitions across all devices

Real-time updates via PubSub subscriptions to `"netboot:devices"` and `"netboot:tftp"` topics.

#### Devices (`/netboot/devices`)

**List view**:
- Table: MAC, hostname, IP, arch, profile, state, last seen, actions
- Filterable by state, profile, arch, tags
- Sortable columns
- Color-coded state badges (green=installed, yellow=booting/installing, red=failed, gray=discovered)

**Device detail** (`/netboot/devices/:mac`):
- Full device record display
- State history timeline
- Assigned boot profile (editable dropdown)
- Hardware info (populated after installer registration)
- Tags (editable)
- Actions: Assign Profile, Request Reinstall, Delete, Boot to Rescue
- Install log (if available)

**Bulk actions**:
- Select multiple → Assign Profile, Request Reinstall, Add Tag

#### Boot Profiles (`/netboot/profiles`)

**List view**:
- Table: name, description, arch support, kernel path, device count using profile
- Create / Edit / Delete actions

**Profile editor** (`/netboot/profiles/:id/edit`):
- Form fields: name, description, kernel, initrd, kernel_args, arch (multi-select), installer_image
- Manifest sub-form: disk_layout, flake URL, slot_strategy, post_install_hooks
- Preview: rendered iPXE script for this profile
- Validation: check that referenced files exist in TFTP root

**Create profile** (`/netboot/profiles/new`):
- Same form as editor
- Option to clone from existing profile

#### TFTP Server (`/netboot/tftp`)

**Status panel**:
- Running/stopped indicator with start/stop toggle
- Port configuration
- TFTP root path
- File count in root

**File browser**:
- Tree view of TFTP root directory
- File sizes, modification dates
- Upload new files (iPXE binaries, kernels, initrds)
- Delete files (with confirmation)
- Refresh / rescan

**Active transfers**:
- Live table: client IP, filename, progress (bytes/total), speed, elapsed time
- Auto-updates via PubSub

**Transfer history**:
- Recent completed/failed transfers
- Filterable by client, filename, status

#### Boot Log (`/netboot/log`)

**Unified activity log**:
- Chronological stream of all netboot events
- Event types: device discovery, boot request, TFTP transfer, state change, install callback, errors
- Filterable by device MAC, event type, time range
- Auto-scroll with pause button
- Export to CSV

### LiveView Implementation Notes

**PubSub topics**:
```elixir
"netboot:devices"          # device state changes
"netboot:devices:#{mac}"   # single device updates
"netboot:tftp"             # TFTP server events
"netboot:tftp:transfers"   # active transfer updates
"netboot:log"              # all events stream
```

**Handle patterns**:
```elixir
# In LiveView mount
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(YellowDog.PubSub, "netboot:devices")
    Phoenix.PubSub.subscribe(YellowDog.PubSub, "netboot:tftp")
  end
  # load initial state from Registry/Store
end

def handle_info({:device_state_changed, device}, socket) do
  # update assigns, stream_insert for device list
end
```

**Components** (reusable across pages):
- `NetbootComponents.state_badge/1` — colored state indicator
- `NetbootComponents.device_row/1` — table row for device list
- `NetbootComponents.transfer_row/1` — active transfer display
- `NetbootComponents.profile_select/1` — profile dropdown
- `NetbootComponents.file_tree/1` — TFTP file browser tree

---

## File Structure

```
apps/yellow_dog_netboot/
├── lib/yellow_dog/netboot/
│   ├── application.ex
│   ├── supervisor.ex
│   ├── tftp/
│   │   ├── server.ex              # UDP listener, RRQ dispatch
│   │   ├── transfer.ex            # Per-transfer worker process
│   │   ├── transfer_supervisor.ex # DynamicSupervisor
│   │   ├── protocol.ex            # TFTP packet encode/decode
│   │   └── file_index.ex          # ETS-cached file lookup
│   ├── device/
│   │   ├── registry.ex            # ETS-backed device store
│   │   ├── device.ex              # Device struct + state machine
│   │   └── persistence.ex         # TOML persistence
│   ├── boot/
│   │   ├── profile.ex             # Boot profile struct + API
│   │   ├── script_engine.ex       # iPXE template rendering
│   │   └── arch.ex                # Architecture detection helpers
│   ├── manifest/
│   │   ├── store.ex               # Profile/manifest config store
│   │   └── manifest.ex            # Install manifest struct
│   └── asset/
│       └── store.ex               # Boot asset file management
├── priv/
│   ├── templates/
│   │   ├── default.ipxe.eex       # Default iPXE template
│   │   └── rescue.ipxe.eex        # Rescue mode template
│   └── netboot.toml               # Default configuration
├── test/
│   ├── tftp/
│   │   ├── server_test.exs
│   │   ├── transfer_test.exs
│   │   └── protocol_test.exs
│   ├── device/
│   │   └── registry_test.exs
│   ├── boot/
│   │   └── script_engine_test.exs
│   └── test_helper.exs
└── mix.exs

# Console routes + LiveView pages:
apps/yellow_dog_console/lib/yellow_dog_console_web/
├── router.ex                           # add /netboot scope
├── live/netboot/
│   ├── dashboard_live.ex
│   ├── devices_live.ex
│   ├── device_detail_live.ex
│   ├── profiles_live.ex
│   ├── profile_editor_live.ex
│   ├── tftp_live.ex
│   └── log_live.ex
└── components/
    └── netboot_components.ex
```

---

## Configuration (TOML)

Integrated into main YellowDog config:

```toml
[services]
netboot = true

[netboot]
tftp_port = 69
tftp_root = "/srv/netboot/tftp"
http_boot_enabled = true
default_profile = "nixos-minimal"
device_persistence_path = "/var/lib/yellowdog/netboot/devices.toml"

[netboot.security]
require_https = false          # phase 1: HTTP ok
device_token_enabled = false   # phase 2: per-device tokens
```

---

## Telemetry Events

```elixir
# TFTP
[:yellow_dog, :netboot, :tftp, :request, :start]
[:yellow_dog, :netboot, :tftp, :request, :stop]
[:yellow_dog, :netboot, :tftp, :transfer, :start]
[:yellow_dog, :netboot, :tftp, :transfer, :stop]
[:yellow_dog, :netboot, :tftp, :transfer, :exception]

# Device lifecycle
[:yellow_dog, :netboot, :device, :discovered]
[:yellow_dog, :netboot, :device, :state_changed]
[:yellow_dog, :netboot, :device, :registered]

# Boot
[:yellow_dog, :netboot, :boot, :script_rendered]
[:yellow_dog, :netboot, :boot, :manifest_served]

# Install callbacks
[:yellow_dog, :netboot, :install, :started]
[:yellow_dog, :netboot, :install, :completed]
[:yellow_dog, :netboot, :install, :failed]
```

---

## Testing Strategy

**Unit tests**:
- TFTP protocol encode/decode (packet fixtures from real PXE clients)
- Device state machine transitions (all valid/invalid paths)
- iPXE script rendering with various profile configs
- Boot profile matching (MAC → profile resolution)
- File index path traversal prevention

**Integration tests**:
- TFTP server: open socket, send RRQ, receive DATA blocks, verify file content
- Device registry: register → state transitions → persistence round-trip
- HTTP boot endpoints: request iPXE script, verify correct profile rendering
- DHCP integration: mock DHCP worker calling `BootProfile.for_device/1`

**LiveView tests**:
- Dashboard renders device counts
- Device list filters and sorts correctly
- Profile editor validates and saves
- PubSub updates propagate to connected clients

---

## Implementation Phases

### Phase 1 — Foundation
- TFTP server (read-only, static file serving)
- Basic device registry (ETS, no persistence)
- DHCP boot option injection (Option 66/67)
- Static iPXE boot chain
- Console: TFTP status page, file browser

### Phase 2 — Dynamic Boot
- Dynamic iPXE script engine with templates
- Boot profile configuration (TOML)
- Device registry with persistence
- HTTP boot endpoints
- Console: Device list, profile editor, dashboard

### Phase 3 — Install Automation
- Install manifest API
- Installer registration/callback endpoints
- Device state machine (full lifecycle)
- Console: Device detail, boot log, bulk actions

### Phase 4 — Hardening (Future)
- HTTPS for iPXE chain
- Per-device install tokens
- A/B slot support in manifest/registry
- Health check and rollback
- Image-based deployment

---

## Acceptance Criteria

### Phase 1
- [ ] TFTP server serves files from configured root directory
- [ ] TFTP rejects WRQ and path traversal attempts
- [ ] DHCP OFFER/ACK includes boot options for PXE clients
- [ ] iPXE binary chainloads successfully from TFTP
- [ ] Console shows TFTP server status and file browser
- [ ] Telemetry events emitted for all TFTP operations

### Phase 2
- [ ] iPXE script dynamically generated per device MAC/arch
- [ ] Boot profiles configurable via TOML and console UI
- [ ] Device registry tracks discovered devices with state
- [ ] Console device list with filtering and profile assignment
- [ ] Hot-reload of boot profiles without restart

### Phase 3
- [ ] Installer fetches manifest from HTTP API
- [ ] Device state transitions through full lifecycle
- [ ] Install success/failure reported back via callback
- [ ] Console shows device detail with state history
- [ ] Boot log with filtering and export

---

## Security Considerations

- TFTP: read-only, no write/delete, path traversal blocked
- HTTP boot endpoints: rate limiting on script generation
- Device registration: validate MAC format, deduplicate
- Phase 2+: per-device tokens for manifest API authentication
- Phase 4: HTTPS required for iPXE chain and install API
- Privileged port 69: requires `CAP_NET_BIND_SERVICE` or root (same pattern as DNS/DHCP)

---

## Dependencies

| Dependency | Usage | Existing? |
|-----------|-------|-----------|
| `abyss` | UDP transport for TFTP server | Yes |
| `yellow_dog` | Core config loading | Yes |
| `yellow_dog_telemetry` | Event emission | Yes |
| `yellow_dog_console` | LiveView UI routes | Yes |
| `yellow_dog_dhcp` | Boot option injection caller | Yes |
| `phoenix_pubsub` | Real-time UI updates | Yes (via console) |
| `eex` | iPXE template rendering | Stdlib |
| `:gen_udp` | TFTP socket (via Abyss or direct) | OTP |