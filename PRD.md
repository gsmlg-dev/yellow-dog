# YellowDog.Fingerprint PRD

## Overview

Passive device identification for YellowDog's DHCPv4 and DHCPv6 servers. Identifies device type, OS, and vendor by analyzing DHCP option patterns without active probing.

**App:** `yellow_dog_fingerprint` (umbrella app)
**Dependencies:** `yellow_dog_telemetry`
**Consumers:** `yellow_dog_console` (LiveView UI), `yellow_dog_dhcpv4`, `yellow_dog_dhcpv6` (telemetry emitters)

**Context:** DHCP clients reveal identity through the options they request and how they identify themselves. DHCPv4 clients send a Parameter Request List (Option 55) with a specific ordering of requested options — this sequence is nearly unique per OS/device stack. DHCPv6 clients similarly expose identity through the Option Request Option (Option 6) and Vendor Class (Option 16). By passively collecting these signals during normal DHCP operations, YellowDog can build a real-time device inventory without any additional network traffic.

## Design Principles

- **Passive** — No active probing; fingerprints extracted from normal DHCP message flow
- **Decoupled** — DHCP servers emit telemetry events; fingerprint app subscribes. No compile-time dependency from DHCP apps to fingerprint app
- **Protocol-agnostic pipeline** — Parsers are protocol-specific; matching, storage, and device registry are shared
- **Local-first** — Local database and user overrides; optional upstream API as fallback
- **Off critical path** — Fingerprint processing never delays DHCP responses

## Data Model

### Fingerprint

A deterministic signature derived from a DHCP message.

```elixir
@type t :: %Fingerprint{
  id: binary(),                  # BLAKE3 hash of canonical form
  protocol: :dhcpv4 | :dhcpv6,
  parameter_list: [non_neg_integer()],  # Option 55 (v4) or Option 6 (v6) values, ordered
  vendor_class: String.t() | nil,       # Option 60 (v4) or Option 16 (v6)
  hostname_pattern: String.t() | nil,   # Option 12 (v4) or Option 39 (v6), normalized
  first_seen: DateTime.t(),
  last_seen: DateTime.t(),
  hit_count: non_neg_integer()
}
```

**Canonical hash:** `BLAKE3(protocol <> ":" <> Enum.join(parameter_list, ",") <> ":" <> (vendor_class || ""))`

The parameter list preserves ordering — `[1,3,6,15]` and `[1,6,3,15]` produce different fingerprints.

### Device Profile

What a fingerprint resolves to — the identity.

```elixir
@type t :: %DeviceProfile{
  id: binary(),
  name: String.t(),              # "Windows 11", "iPhone 15", "Cisco IP Phone 7960"
  os_family: String.t() | nil,   # "Windows", "iOS", "Android", "Linux"
  os_version: String.t() | nil,  # "11", "17.2", "14"
  device_type: device_type(),    # :computer, :phone, :tablet, :printer, :iot, ...
  vendor: String.t() | nil,      # "Apple", "Samsung", "Cisco"
  confidence: non_neg_integer(), # 0-100
  source: :local | :fingerbank | :user_override
}

@type device_type ::
  :computer | :phone | :tablet | :printer | :voip_phone |
  :camera | :tv | :game_console | :iot | :network_equipment |
  :server | :virtual_machine | :container | :unknown
```

### Device

An observed network entity. Correlates v4 and v6 observations.

```elixir
@type t :: %Device{
  id: binary(),                       # Primary key (generated)
  mac: String.t(),                    # MAC address, normalized "aa:bb:cc:dd:ee:ff"
  oui_vendor: String.t() | nil,       # IEEE OUI resolved vendor
  duid: binary() | nil,               # DHCPv6 DUID (if observed)
  ipv4_addresses: [String.t()],       # Currently/recently assigned v4 addresses
  ipv6_addresses: [String.t()],       # Currently/recently assigned v6 addresses
  hostname: String.t() | nil,         # Last observed hostname
  fingerprint_v4_id: binary() | nil,  # Current v4 fingerprint hash
  fingerprint_v6_id: binary() | nil,  # Current v6 fingerprint hash
  profile_id: binary() | nil,         # Best-match device profile
  profile_confidence: non_neg_integer(),
  first_seen: DateTime.t(),
  last_seen: DateTime.t(),
  observation_count: non_neg_integer(),
  metadata: map()                     # Extensible: relay info, VLAN, etc.
}
```

**Device identity key:** MAC address is the primary correlation key between v4 and v6 observations. For v6-only environments without MAC visibility, DUID serves as fallback identifier.

### OUI Entry

IEEE OUI vendor lookup.

```elixir
@type t :: %OUI{
  prefix: binary(),       # "AA:BB:CC" (3-byte) or "AA:BB:CC:DD" (4-byte MA-M/MA-S)
  vendor: String.t(),
  short_name: String.t()  # Abbreviated vendor name
}
```

## Fingerprint Extraction

### DHCPv4 Signals

Extracted from DISCOVER and REQUEST messages:

| Signal | DHCP Option | Weight | Notes |
|--------|-------------|--------|-------|
| Parameter Request List | Option 55 | Primary | Ordered list of requested option codes |
| Vendor Class Identifier | Option 60 | High | e.g., `MSFT 5.0`, `android-dhcp-12`, `udhcp 1.24.2` |
| Hostname | Option 12 | Low | Naming patterns hint at device type |
| Client Identifier | Option 61 | Correlation | Usually contains MAC |
| Max Message Size | Option 57 | Supplementary | Stack-specific default values |
| Client Architecture | Option 93 | Supplementary | PXE boot environment type |

### DHCPv6 Signals

Extracted from SOLICIT and REQUEST messages:

| Signal | DHCP Option | Weight | Notes |
|--------|-------------|--------|-------|
| Option Request | Option 6 | Primary | Ordered list of requested option codes |
| Vendor Class | Option 16 | High | Enterprise number + vendor data |
| Client FQDN | Option 39 | Low | Hostname pattern |
| DUID | Option 1 | Correlation | Type reveals stack: DUID-LLT (type 1), DUID-EN (type 2), DUID-LL (type 3), DUID-UUID (type 4) |
| IA_NA/IA_PD presence | Options 3/25 | Supplementary | Requesting addresses vs prefixes distinguishes hosts from routers |
| Elapsed Time | Option 8 | Supplementary | Retransmission behavior varies by stack |

### DUID Type Analysis

The DUID type itself is a fingerprint signal:

- **DUID-LLT (1):** Contains hardware type + time + link-layer address. Extract MAC for OUI. Common in dhclient, Windows.
- **DUID-EN (2):** Contains enterprise number (IANA PEN). Identifies software vendor, not hardware. e.g., PEN 43793 = systemd-networkd.
- **DUID-LL (3):** Contains hardware type + link-layer address. Extract MAC for OUI. Common in ISC DHCP.
- **DUID-UUID (4):** Opaque UUID. No vendor extraction possible. Common in modern systemd.

## Telemetry Events

DHCP servers emit raw option data. No dependency on fingerprint app.

### Emitted by DHCPv4 Server

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :message, :received],
  %{timestamp: System.monotonic_time()},
  %{
    message_type: :discover | :request | :inform,
    chaddr: <<mac::binary-6>>,
    option_55: [1, 3, 6, 15, 119, 252],
    option_60: "MSFT 5.0",
    option_12: "DESKTOP-ABC123",
    option_61: <<client_id::binary>>,
    source_ip: {192, 168, 1, 100},
    gateway_ip: {0, 0, 0, 0},
    interface: "eth0"
  }
)
```

### Emitted by DHCPv6 Server

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv6, :message, :received],
  %{timestamp: System.monotonic_time()},
  %{
    message_type: :solicit | :request | :information_request,
    duid: <<duid::binary>>,
    option_6: [23, 24, 39, 73],
    option_16: %{enterprise_id: 43793, data: <<vendor_data::binary>>},
    option_39: "host.example.com",
    has_ia_na: true,
    has_ia_pd: false,
    source_ip: {0xfe80, 0, 0, 0, 0x1234, 0x56ff, 0xfe78, 0x9abc},
    interface: "eth0"
  }
)
```

### Emitted by Fingerprint App

```elixir
# Device identified or updated
[:yellow_dog, :fingerprint, :device, :identified]
metadata: %{mac: mac, profile: profile_name, confidence: score, new_device: boolean}

# Unknown fingerprint observed
[:yellow_dog, :fingerprint, :unknown]
metadata: %{fingerprint_id: hash, protocol: :dhcpv4 | :dhcpv6, parameter_list: [...]}

# Fingerprint changed for known device (possible OS upgrade/change)
[:yellow_dog, :fingerprint, :device, :changed]
metadata: %{mac: mac, old_profile: name, new_profile: name}
```

## Matching Engine

### Match Flow

```
Raw DHCP options
  │
  ├─ Parser.V4 or Parser.V6
  │   └─ Extract signals → %Fingerprint{}
  │
  ├─ Compute canonical hash
  │
  ├─ Exact match (ETS lookup by hash)
  │   ├─ Hit → return %DeviceProfile{} with confidence
  │   └─ Miss ↓
  │
  ├─ Fuzzy match (parameter list similarity)
  │   ├─ Jaccard similarity on option set (ignoring order)
  │   ├─ Ordered subsequence bonus
  │   ├─ Threshold: >= 0.8 similarity
  │   └─ Best match → return %DeviceProfile{} with reduced confidence
  │
  ├─ Vendor class match (regex patterns)
  │   ├─ "MSFT 5.0" → Windows
  │   ├─ "android-dhcp-*" → Android
  │   ├─ "udhcp*" → Embedded Linux
  │   └─ Match → return %DeviceProfile{} with medium confidence
  │
  ├─ Fingerbank API fallback (optional, if configured)
  │   ├─ POST /api/v2/combinations/interrogate
  │   ├─ Cache result locally on success
  │   └─ Rate limited: max 300/hr
  │
  └─ No match → register as unknown, OUI enrichment only
```

### Confidence Scoring

| Match Type | Base Confidence | Notes |
|------------|----------------|-------|
| Exact hash match (local override) | 95-100 | User classified |
| Exact hash match (fingerbank DB) | 80-95 | Depends on DB confidence |
| Fuzzy match (>= 0.9 Jaccard) | 60-80 | Reduced by delta from exact |
| Fuzzy match (>= 0.8 Jaccard) | 40-60 | Low confidence |
| Vendor class only | 30-50 | Broad category only |
| Fingerbank API result | Per API | Score 0-100 from API |
| OUI only | 10-20 | Manufacturer known, device type unknown |

### Priority

1. User overrides (`:user_override`) — always win
2. Local database exact match
3. Local database fuzzy match
4. Fingerbank API (if enabled)
5. OUI-only identification

## Fingerprint Database

### Local Database

ETS-backed, loaded from TOML at boot. Two tiers:

**Bundled database** — shipped with YellowDog, seeded from Fingerbank's open dataset (ODbL licensed). Approximately 15k DHCPv4 fingerprints, sparse DHCPv6 coverage.

**User overrides** — managed via LiveView console. Stored in `data/fingerprint/overrides.toml`. Always take priority over bundled data.

### Database Schema (TOML)

**`data/fingerprint/profiles.toml`** — Bundled device profiles:

```toml
[[profiles]]
id = "windows-11"
name = "Windows 11"
os_family = "Windows"
os_version = "11"
device_type = "computer"
vendor = "Microsoft"

[[profiles]]
id = "iphone-ios17"
name = "iPhone (iOS 17)"
os_family = "iOS"
os_version = "17"
device_type = "phone"
vendor = "Apple"
```

**`data/fingerprint/fingerprints_v4.toml`** — DHCPv4 fingerprint → profile mappings:

```toml
[[fingerprints]]
parameter_list = [1, 121, 3, 6, 15, 114, 119, 252]
vendor_class_pattern = "MSFT 5.0"
profile_id = "windows-11"
confidence = 90

[[fingerprints]]
parameter_list = [1, 121, 3, 6, 15, 119, 252]
vendor_class_pattern = "android-dhcp-*"
profile_id = "android-generic"
confidence = 75
```

**`data/fingerprint/fingerprints_v6.toml`** — DHCPv6 fingerprint → profile mappings:

```toml
[[fingerprints]]
parameter_list = [1, 2, 3, 6, 11, 12, 23, 24, 39, 73, 74]
duid_type = 4
enterprise_id = 43793
profile_id = "linux-systemd"
confidence = 70
```

**`data/fingerprint/overrides.toml`** — User-managed overrides:

```toml
[[overrides]]
fingerprint_hash = "a1b2c3d4..."
profile_id = "custom-iot-sensor"
note = "Floor 3 temperature sensors"
created_at = 2026-01-15T10:30:00Z

[[custom_profiles]]
id = "custom-iot-sensor"
name = "AcmeCorp Temperature Sensor v2"
device_type = "iot"
vendor = "AcmeCorp"
```

### OUI Database

IEEE MA-L/MA-M/MA-S database. Loaded from `data/fingerprint/oui.txt` (IEEE format). Updated manually or via scheduled download from `https://standards-oui.ieee.org/oui/oui.txt`.

### Device Registry

Runtime state of observed devices. Persisted to `data/fingerprint/devices.toml` periodically (flush interval: 60s, immediate on shutdown). Consistent with DHCP pool persistence pattern.

```toml
[[devices]]
mac = "aa:bb:cc:dd:ee:ff"
oui_vendor = "Apple, Inc."
hostname = "iPhone"
fingerprint_v4_id = "a1b2c3d4..."
profile_id = "iphone-ios17"
profile_confidence = 90
first_seen = 2026-01-01T00:00:00Z
last_seen = 2026-02-09T12:00:00Z
observation_count = 147
ipv4_addresses = ["192.168.1.42"]
ipv6_addresses = ["fd00::1234"]
```

## Fingerbank API Integration

Optional upstream integration. Disabled by default.

### Configuration

```toml
[fingerprint.fingerbank]
enabled = false
api_key = ""
base_url = "https://api.fingerbank.org"
cache_ttl_hours = 168           # 7 days
rate_limit_per_hour = 300
submit_unknown = false          # Submit unknown fingerprints upstream
```

### API Usage

Query: `GET /api/v2/combinations/interrogate`

```json
{
  "dhcp_fingerprint": "1,121,3,6,15,119,252",
  "dhcp_vendor": "dhcpcd-5.5.6",
  "mac": "aabbccddeeff"
}
```

Response includes device hierarchy, name, and confidence score (0-100).

Results cached locally in ETS with TTL. Cached results persisted across restarts in `data/fingerprint/.cache/fingerbank_cache.toml`.

### DHCPv6 API Support

Fingerbank supports DHCPv6 fingerprints via `dhcp6_fingerprint` and `dhcp6_enterprise` fields:

```json
{
  "dhcp6_fingerprint": "1,2,3,6,11,12,23,24,39,73,74",
  "dhcp6_enterprise": "43793",
  "mac": "aabbccddeeff"
}
```

## Process Architecture

```
yellow_dog_fingerprint (Application)
├── Fingerprint.Supervisor
│   ├── Fingerprint.Observer          # Telemetry handler, routes to workers
│   ├── Fingerprint.Database          # ETS tables, TOML load/save
│   ├── Fingerprint.DeviceRegistry    # Device state, periodic flush
│   ├── Fingerprint.OUI              # OUI lookup table
│   └── Fingerprint.FingerbankClient  # Optional API client (GenServer)
```

**Observer** attaches to telemetry events on `init/1`. Extracts fingerprint, runs match pipeline, updates device registry. All processing is synchronous within the telemetry handler — acceptable because fingerprinting is cheap (ETS lookups) and DHCP message rate is low (tens per second, not thousands).

If Fingerbank API fallback is needed (cache miss for unknown fingerprint), the observer spawns a `Task` to avoid blocking the telemetry handler. The task result updates ETS asynchronously.

## LiveView Console

### Device Inventory Page (`/devices`)

Real-time device table via `Phoenix.PubSub`:

- **Columns:** MAC, IP(s), Hostname, Device Type, OS, Vendor (OUI), Profile, Confidence, First Seen, Last Seen
- **Sort:** Any column, default by last_seen desc
- **Filter:** Device type, OS family, vendor, confidence threshold, subnet, "unknown only"
- **Search:** MAC, hostname, IP
- **Live updates:** New devices appear immediately, last_seen updates in real-time
- **Export:** CSV download of current filtered view

### Fingerprint Management Page (`/fingerprints`)

- **Known fingerprints:** Browse with matched profile, hit count, last seen
- **Unknown fingerprints:** Ranked by frequency (most-seen first). This is the primary actionable list.
- **Classify unknown:** Select unknown fingerprint → assign existing or create new profile → saves to overrides.toml
- **Import/Export:** Upload/download fingerprint database (TOML format)

### Device Detail Page (`/devices/:mac`)

- Protocol correlation: side-by-side v4 and v6 fingerprint
- DHCP interaction timeline (leases, renewals, releases)
- Fingerprint change history (OS upgrade detection)
- Raw fingerprint data display

### Dashboard Widgets (`/dashboard`)

Available as components for the main YellowDog dashboard:

- Device type distribution (bar chart)
- New devices over time (line chart)
- Unknown fingerprint count (metric card, links to classification page)
- Top vendors (pie chart)

## PubSub Topics

```elixir
# New device or device update — LiveView subscribes
Phoenix.PubSub.broadcast(YellowDog.PubSub, "fingerprint:devices", {:device_updated, device})

# New unknown fingerprint — dashboard widget subscribes
Phoenix.PubSub.broadcast(YellowDog.PubSub, "fingerprint:unknown", {:new_unknown, fingerprint})

# Fingerprint change detected — alert/notification
Phoenix.PubSub.broadcast(YellowDog.PubSub, "fingerprint:changes", {:profile_changed, mac, old, new})
```

## File Structure

```
apps/yellow_dog_fingerprint/
├── lib/yellow_dog/fingerprint/
│   ├── application.ex
│   ├── supervisor.ex
│   ├── observer.ex             # Telemetry event handler
│   ├── database.ex             # ETS tables, TOML load/save
│   ├── device_registry.ex      # Device state management
│   ├── matcher.ex              # Match pipeline
│   ├── oui.ex                  # OUI lookup
│   ├── fingerbank_client.ex    # Optional API client
│   ├── parser/
│   │   ├── v4.ex               # DHCPv4 signal extraction
│   │   └── v6.ex               # DHCPv6 signal extraction
│   └── types/
│       ├── fingerprint.ex
│       ├── device_profile.ex
│       └── device.ex
├── test/yellow_dog/fingerprint/
│   ├── observer_test.exs
│   ├── database_test.exs
│   ├── matcher_test.exs
│   ├── device_registry_test.exs
│   ├── oui_test.exs
│   └── parser/
│       ├── v4_test.exs
│       └── v6_test.exs
└── mix.exs
```

Data directory:

```
data/fingerprint/
├── profiles.toml               # Bundled device profiles
├── fingerprints_v4.toml        # Bundled v4 fingerprint mappings
├── fingerprints_v6.toml        # Bundled v6 fingerprint mappings
├── overrides.toml              # User-managed overrides + custom profiles
├── devices.toml                # Persisted device registry
├── oui.txt                     # IEEE OUI database
└── .cache/
    └── fingerbank_cache.toml   # Cached API results
```

## Configuration

```toml
[fingerprint]
enabled = true
device_flush_interval_ms = 60000
max_devices = 10000
unknown_retention_days = 90

[fingerprint.matching]
fuzzy_threshold = 0.8
vendor_class_enabled = true

[fingerprint.fingerbank]
enabled = false
api_key = ""
cache_ttl_hours = 168
rate_limit_per_hour = 300
submit_unknown = false

[fingerprint.oui]
path = "data/fingerprint/oui.txt"
```

## Testing Requirements

### Unit Tests

1. **Parser.V4** — Extract fingerprint from raw v4 options; handle missing/malformed options
2. **Parser.V6** — Extract fingerprint from raw v6 options; DUID type parsing; enterprise ID extraction
3. **Matcher** — Exact match; fuzzy match at various thresholds; vendor class regex matching; priority ordering (user override > local > API)
4. **OUI** — 3-byte and 4-byte prefix lookup; unknown MAC handling
5. **Database** — TOML round-trip; override priority; hash computation consistency
6. **DeviceRegistry** — Create/update device; v4+v6 correlation by MAC; fingerprint change detection

### Integration Tests

1. **End-to-end observation** — Emit telemetry event → observer processes → device appears in registry
2. **LiveView updates** — Device registry change → PubSub → LiveView receives update
3. **Persistence** — Registry flush → restart → devices recovered
4. **Fingerbank API** — Mock API response → cached locally → used on subsequent lookup

### Property-Based Tests

1. **Hash determinism** — Same inputs always produce same fingerprint hash
2. **Fuzzy symmetry** — similarity(A, B) == similarity(B, A)
3. **TOML round-trip** — All types serialize and deserialize without loss

## Out of Scope

- Active probing (nmap-style)
- TCP/IP stack fingerprinting (p0f)
- HTTP User-Agent fingerprinting (no HTTP visibility)
- RADIUS/802.1X integration
- Multi-node device registry replication
- Automatic OUI database updates (manual download for v1)

## Acceptance Criteria

- [ ] DHCPv4 fingerprints extracted from DISCOVER/REQUEST messages
- [ ] DHCPv6 fingerprints extracted from SOLICIT/REQUEST messages
- [ ] Exact match against local fingerprint database works
- [ ] Fuzzy matching identifies close variants
- [ ] OUI lookup resolves MAC → vendor
- [ ] Device registry correlates v4 and v6 by MAC
- [ ] Fingerprint change detection triggers event
- [ ] User overrides take priority over bundled database
- [ ] Device registry persists across restarts
- [ ] LiveView device inventory shows real-time updates
- [ ] Unknown fingerprints surfaced for manual classification
- [ ] Fingerbank API integration works when enabled
- [ ] Unit and integration tests pass
- [ ] TOML schema documented with examples