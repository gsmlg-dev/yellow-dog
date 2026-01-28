# DHCP Pool Persistence PRD

## Overview

Persistent storage for DHCPv4 and DHCPv6 address pools in YellowDog. Pools store subnet configuration, allocation ranges, static reservations, and active leases. Data persists across service restarts with transactional write safety.

**Context:** YellowDog DHCP services require durable pool state for:
- Lease continuity across restarts
- Static reservation management
- Pool configuration without code changes
- ACL support based on MAC/DUID and DHCP options

## Design Principles

- **Separated by protocol** - v4 and v6 in distinct directories, no version field needed
- **Config/lease split** - Stable config separate from volatile lease data
- **Transactional writes** - Atomic updates with validation and rollback capability
- **TOML format** - Human-readable, easy manual editing when needed

## Directory Structure

```
data/
├── dns/
│   └── ...
├── dhcpv4/
│   ├── pools.toml              # Pool index
│   ├── pools/
│   │   ├── lan.toml            # Pool config
│   │   └── guest.toml
│   ├── leases/
│   │   ├── lan.toml            # Active leases
│   │   └── guest.toml
│   └── .cache/                 # Transaction staging
├── dhcpv6/
│   ├── pools.toml              # Pool index
│   ├── pools/
│   │   └── main.toml
│   ├── leases/
│   │   └── main.toml
│   └── .cache/
└── mdns/
    └── ...
```

## Data Structures

### Poolv4

```elixir
defmodule YellowDog.DHCPv4.Pool do
  @type t :: %__MODULE__{
    name: String.t(),
    subnet: {:inet.ip4_address(), prefix_len :: 0..32},
    range: {:inet.ip4_address(), :inet.ip4_address()},
    gateway: :inet.ip4_address() | nil,
    dns_servers: [:inet.ip4_address()],
    lease_time: %{default: pos_integer(), max: pos_integer()},
    reservations: %{mac_address() => :inet.ip4_address()},
    options: %{option_code() => binary()},
    acl: acl_config()
  }

  @type mac_address :: <<_::48>>
  @type option_code :: 1..254
  @type acl_config :: %{
    allow: [acl_rule()],
    deny: [acl_rule()]
  }
  @type acl_rule :: {:mac, mac_pattern()} | {:option, option_code(), binary()}
end
```

### Poolv6

```elixir
defmodule YellowDog.DHCPv6.Pool do
  @type t :: %__MODULE__{
    name: String.t(),
    prefix: {:inet.ip6_address(), prefix_len :: 0..128},
    mode: :slaac | :stateful | :stateless,
    range: {:inet.ip6_address(), :inet.ip6_address()} | nil,
    dns_servers: [:inet.ip6_address()],
    lifetimes: %{preferred: pos_integer(), valid: pos_integer()},
    reservations: %{duid() => :inet.ip6_address()},
    pd_pools: [pd_pool()],
    options: %{option_code() => binary()},
    acl: acl_config()
  }

  @type duid :: binary()
  @type pd_pool :: %{prefix: :inet.ip6_address(), length: 48..64, delegated_len: 48..64}
  @type option_code :: 1..65535
end
```

### Leasev4

```elixir
defmodule YellowDog.DHCPv4.Lease do
  @type t :: %__MODULE__{
    ip: :inet.ip4_address(),
    mac: mac_address(),
    hostname: String.t() | nil,
    client_id: binary() | nil,
    starts_at: DateTime.t(),
    expires_at: DateTime.t(),
    state: :active | :offered | :declined
  }
end
```

### Leasev6

```elixir
defmodule YellowDog.DHCPv6.Lease do
  @type t :: %__MODULE__{
    ip: :inet.ip6_address(),
    duid: binary(),
    iaid: non_neg_integer(),
    hostname: String.t() | nil,
    starts_at: DateTime.t(),
    preferred_until: DateTime.t(),
    valid_until: DateTime.t(),
    state: :active | :offered | :declined
  }
end
```

## File Schemas

### Index File (`pools.toml`)

```toml
# data/dhcpv4/pools.toml
[[pools]]
name = "lan"
path = "pools/lan.toml"
enabled = true

[[pools]]
name = "guest"
path = "pools/guest.toml"
enabled = true
```

### Pool Config File (v4)

```toml
# data/dhcpv4/pools/lan.toml
name = "lan"

[subnet]
address = "192.168.1.0"
prefix_len = 24

[range]
start = "192.168.1.100"
end = "192.168.1.200"

gateway = "192.168.1.1"
dns_servers = ["192.168.1.1", "8.8.8.8"]

[lease_time]
default = 3600
max = 86400

[reservations]
"aa:bb:cc:dd:ee:01" = "192.168.1.10"
"aa:bb:cc:dd:ee:02" = "192.168.1.11"

[options]
# Option 66: TFTP server
66 = "192.168.1.5"
# Option 67: Boot filename
67 = "pxelinux.0"

[acl]
# Empty = allow all
allow = []
deny = []

[[acl.allow]]
type = "mac"
pattern = "aa:bb:cc:*"

[[acl.deny]]
type = "option"
code = 60  # Vendor class
value = "blocked-vendor"
```

### Pool Config File (v6)

```toml
# data/dhcpv6/pools/main.toml
name = "main"
mode = "stateful"  # slaac | stateful | stateless

[prefix]
address = "2001:db8:1::"
prefix_len = 64

[range]
start = "2001:db8:1::1000"
end = "2001:db8:1::1fff"

dns_servers = ["2001:db8:1::1", "2001:4860:4860::8888"]

[lifetimes]
preferred = 3600
valid = 7200

[reservations]
# DUID (hex encoded) -> IPv6
"000100011234567890abcdef" = "2001:db8:1::10"

[[pd_pools]]
prefix = "2001:db8:f000::"
length = 48
delegated_len = 56

[options]
# Option 23: DNS recursive name server (handled separately via dns_servers)
# Option 24: Domain search list
24 = "example.com"

[acl]
allow = []
deny = []
```

### Lease File (v4)

```toml
# data/dhcpv4/leases/lan.toml
# Auto-generated - do not edit while service running

[[leases]]
ip = "192.168.1.100"
mac = "aa:bb:cc:dd:ee:ff"
hostname = "workstation1"
client_id = "01aabbccddeeff"
starts_at = "2025-01-28T10:00:00Z"
expires_at = "2025-01-28T11:00:00Z"
state = "active"

[[leases]]
ip = "192.168.1.101"
mac = "11:22:33:44:55:66"
starts_at = "2025-01-28T10:30:00Z"
expires_at = "2025-01-28T11:30:00Z"
state = "active"
```

### Lease File (v6)

```toml
# data/dhcpv6/leases/main.toml
# Auto-generated - do not edit while service running

[[leases]]
ip = "2001:db8:1::1000"
duid = "000100011234567890abcdef"
iaid = 1
hostname = "server1"
starts_at = "2025-01-28T10:00:00Z"
preferred_until = "2025-01-28T11:00:00Z"
valid_until = "2025-01-28T12:00:00Z"
state = "active"
```

## Persistence Protocol

```elixir
defprotocol YellowDog.DHCP.Persistable do
  @doc "Serialize to TOML string"
  @spec to_toml(t()) :: String.t()
  
  @doc "Validate struct integrity"
  @spec validate(t()) :: :ok | {:error, term()}
end
```

### Store Modules

```elixir
defmodule YellowDog.DHCPv4.PoolStore do
  @data_dir Application.compile_env(:yellow_dog, [:data_dir], "data")
  
  @spec base_path() :: Path.t()
  @spec load_index() :: {:ok, [pool_entry()]} | {:error, term()}
  @spec load_pool(name :: String.t()) :: {:ok, Pool.t()} | {:error, term()}
  @spec save_pool(Pool.t()) :: :ok | {:error, term()}
  @spec load_leases(pool_name :: String.t()) :: {:ok, [Lease.t()]} | {:error, term()}
  @spec save_leases(pool_name :: String.t(), [Lease.t()]) :: :ok | {:error, term()}
end

defmodule YellowDog.DHCPv6.PoolStore do
  # Mirror API for v6
end
```

## Safe Write Transaction

Atomic file updates with validation and recovery.

### Transaction Steps

```
save(data, target_path):
  1. Generate transaction ID (UUID)
  2. cache_path = .cache/{tx_id}.toml
  3. backup_path = .cache/{tx_id}.backup
  
  4. Write serialized data → cache_path
  5. Parse cache_path → validate round-trip
     - On failure: delete cache_path, return error
  
  6. If target_path exists:
     - Copy target_path → backup_path
  
  7. Rename cache_path → target_path (atomic on POSIX)
     - On failure: restore from backup_path if exists
  
  8. Delete backup_path
  9. Return :ok
```

### Implementation

```elixir
defmodule YellowDog.DHCP.SafeWriter do
  @spec write(path :: Path.t(), content :: String.t(), validator :: (Path.t() -> :ok | {:error, term()})) ::
    :ok | {:error, term()}
  
  @spec with_transaction(base_dir :: Path.t(), (cache_path :: Path.t() -> :ok | {:error, term()})) ::
    :ok | {:error, term()}
end
```

## Lease Persistence Strategy

### Write Frequency

Leases change frequently. Two strategies:

1. **Immediate write** - Every lease change triggers disk write
   - Pro: No data loss on crash
   - Con: High I/O, potential bottleneck

2. **Periodic flush** - Buffer changes, write every N seconds
   - Pro: Batched I/O, better performance
   - Con: Potential lease loss on crash (bounded by flush interval)

**Recommendation:** Periodic flush with configurable interval (default 30s), immediate flush on graceful shutdown.

### Lease File Locking

Single writer (pool GenServer owns lease state), no locking needed. File is authoritative only at startup; runtime state is in-memory.

## Reload Mechanism

### Pool Config Reload

```elixir
# Trigger reload via GenServer call
YellowDog.DHCPv4.PoolManager.reload_pool("lan")

# Pool process:
# 1. Read new config from disk
# 2. Validate against current leases (no conflicts)
# 3. Hot-swap config, keep lease state
# 4. Log changes
```

### Lease Recovery at Startup

```elixir
# On pool start:
# 1. Load pool config
# 2. Load leases from disk
# 3. Filter expired leases
# 4. Validate leases against pool config (range, reservations)
# 5. Initialize in-memory state
```

## API Specification

### PoolStore

```elixir
@spec list_pools() :: {:ok, [String.t()]} | {:error, term()}
@spec get_pool(name :: String.t()) :: {:ok, Pool.t()} | {:error, :not_found | term()}
@spec create_pool(Pool.t()) :: :ok | {:error, :exists | :invalid | term()}
@spec update_pool(Pool.t()) :: :ok | {:error, :not_found | :invalid | term()}
@spec delete_pool(name :: String.t()) :: :ok | {:error, :not_found | :has_leases | term()}
```

### LeaseStore

```elixir
@spec get_leases(pool_name :: String.t()) :: {:ok, [Lease.t()]} | {:error, term()}
@spec flush_leases(pool_name :: String.t(), [Lease.t()]) :: :ok | {:error, term()}
```

## Configuration

```toml
# config.toml
[dhcpv4.persistence]
data_dir = "data/dhcpv4"
lease_flush_interval_ms = 30000
max_backups = 5

[dhcpv6.persistence]
data_dir = "data/dhcpv6"
lease_flush_interval_ms = 30000
max_backups = 5
```

## Testing Requirements

### Unit Tests

1. **Serialization round-trip**
   - Pool struct → TOML → Pool struct (equality)
   - Lease struct → TOML → Lease struct (equality)

2. **Validation**
   - Invalid subnet/range combinations rejected
   - Overlapping reservations rejected
   - Invalid IP formats rejected

3. **Safe writer**
   - Successful write creates file
   - Failed validation leaves original intact
   - Backup created and cleaned up

### Integration Tests

1. **Pool lifecycle**
   - Create pool → reload service → pool exists
   - Update pool → reload → changes persist
   - Delete pool → reload → pool gone

2. **Lease persistence**
   - Allocate lease → flush → restart → lease recovered
   - Expired leases filtered on recovery

3. **Concurrent access**
   - Multiple reads safe
   - Write during read doesn't corrupt

## File Structure

```
apps/yellow_dog_dhcp/
├── lib/yellow_dog_dhcp/
│   ├── v4/
│   │   ├── pool.ex
│   │   ├── lease.ex
│   │   └── pool_store.ex
│   ├── v6/
│   │   ├── pool.ex
│   │   ├── lease.ex
│   │   └── pool_store.ex
│   └── persistence/
│       ├── safe_writer.ex
│       └── toml_codec.ex
└── test/yellow_dog_dhcp/
    ├── v4/pool_store_test.exs
    ├── v6/pool_store_test.exs
    └── persistence/safe_writer_test.exs
```

## Out of Scope

- Database backend (SQLite, etc.) - TOML files sufficient for expected scale
- Replication / HA - single node initially
- Remote API for pool management - local file access only
- Lease history / audit log - current state only

## Acceptance Criteria

- [ ] Pool config loads from TOML on service start
- [ ] Pool config changes persist across restarts
- [ ] Leases survive service restart (within flush interval)
- [ ] Invalid config rejected with clear error
- [ ] Safe write prevents corruption on crash
- [ ] Expired leases pruned on startup
- [ ] ACL rules filter DHCP clients correctly
- [ ] Static reservations honored
- [ ] Prefix delegation pools work (v6)
- [ ] Unit and integration tests pass
- [ ] Documentation with TOML schema examples