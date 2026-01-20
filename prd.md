# YellowDog DHCP Service Data Persistence - PRD (Updated)

## Overview

**Objective**: Persistent storage layer for DHCPv4/v6 service state, enabling lease management, address allocation, ACL enforcement, and custom option delivery across service restarts.

**Scope**: Both `YellowDog.Dhcpv4` and `YellowDog.Dhcpv6` applications within the umbrella architecture.

---

## Problem Statement

DHCP services require persistent state to:
- Maintain lease consistency across restarts
- Enforce address allocation policies
- Apply client-specific ACLs and options
- Support network topology requirements (subnets, ranges, reservations)

Current in-memory-only operation loses all state on service restart, breaking RFC compliance and operational requirements.

---

## Data Model

### Address Pools

**DHCPv4 Pool**:
- Subnet CIDR (network/prefix)
- Available range(s) within subnet
- Gateway address
- DNS servers (list)
- Domain name
- Lease duration (default, min, max)
- Static reservations (MAC → IP mapping)

**DHCPv6 Pool**:
- Prefix delegation support (IA_PD)
- Address assignment ranges (IA_NA)
- Temporary addresses (IA_TA)
- DNS servers (recursive, search list)
- Lease lifetimes (preferred, valid)
- Static assignments (DUID → address/prefix)

**Common**:
- Pool identifier (unique name)
- Priority/weight (for pool selection)
- Enabled/disabled state
- Metrics (utilization, lease count)
- Max leases per pool (default: 1000)

### Leases

**Active Lease Record**:
- Client identifier (MAC/DUID)
- Assigned address/prefix
- Pool reference
- Lease start time
- Lease expiration time
- Renewal time (T1)
- Rebind time (T2)
- Client hostname (option 12/39)
- Vendor class identifier
- State (offered, bound, expired)
- Conflict count (for tracking reassignment)

**Lease States**:
- `offered` - DHCPv4 OFFER sent, awaiting REQUEST
- `bound` - Active lease
- `released` - Client released early
- `expired` - Lease timeout reached
- `declined` - Address conflict detected, auto-reassigning

**Lease Limits**:
- Default max per pool: 1000 leases
- Configurable per-pool override
- Pool allocation fails when limit reached

### Access Control Lists (ACL)

**MAC-based ACL** (v4):
- MAC address or pattern (glob/regex)
- Action: allow, deny, pool_assignment
- Target pool identifier (if allow)
- Priority order

**DUID-based ACL** (v6):
- DUID or pattern
- Action: allow, deny, pool_assignment
- Target pool/prefix
- Priority order

**Option-based ACL**:
- Match conditions:
  - Vendor Class Identifier (v4 opt 60, v6 opt 16)
  - User Class (v4 opt 77, v6 opt 15)
  - Client Architecture (v4 opt 93, v6 opt 61)
  - Relay Agent Information (v4 opt 82, v6 opt 37)
- Action: pool_assignment, custom_options, deny
- Target configuration

### Custom Options

**Option Definition**:
- Option code (1-254 for v4, 1-65535 for v6)
- Option name
- Data type (ip, string, uint8, uint16, uint32, hex)
- Value or value template

**Option Sets**:
- Set identifier
- List of option definitions
- Application scope:
  - Global (all clients)
  - Per-pool
  - Per-ACL match
  - Per-static reservation

**Template Variables** (simple substitution only):
- `${client_mac}` - Client MAC address (v4)
- `${client_duid}` - Client DUID (v6)
- `${client_hostname}` - Requested hostname
- `${lease_address}` - Assigned IP/prefix
- `${pool_name}` - Pool identifier

**Standard Option Overrides**:
- Allow per-pool/per-client override of standard options
- Examples: NTP servers, TFTP boot file, SIP servers

---

## Storage Architecture

### Backend Selection

Support pluggable backends via behavior:
- **ETS** (default) - In-memory with periodic snapshots to TOML
- **DETS** - Disk-based ETS for persistence
- **Mnesia** - Distributed, transactional (future clustering)
- **External** - PostgreSQL/SQLite via Ecto (high-scale deployments)

### Data Organization

```
config/
  dhcpv4_pools.toml      # Pool definitions
  dhcpv6_pools.toml
  dhcp_acls.toml         # ACL rules
  dhcp_options.toml      # Custom option sets

data/
  dhcpv4_leases.dets     # Active leases
  dhcpv6_leases.dets
  dhcp_metrics.dets      # Counters, statistics
```

### TOML Schema

**Pool Configuration** (`dhcpv4_pools.toml`):
```toml
[[pools]]
name = "office_network"
enabled = true
subnet = "192.168.1.0/24"
ranges = ["192.168.1.100-192.168.1.200"]
gateway = "192.168.1.1"
dns_servers = ["8.8.8.8", "8.8.4.4"]
domain = "office.local"
lease_time = 86400
max_leases = 1000  # default
priority = 100

[[pools.reservations]]
mac = "aa:bb:cc:dd:ee:ff"
address = "192.168.1.50"
hostname = "printer-01"
```

**ACL Configuration** (`dhcp_acls.toml`):
```toml
[[rules]]
priority = 10
type = "mac"
pattern = "aa:bb:cc:*"
action = "allow"
target_pool = "office_network"

[[rules]]
priority = 20
type = "vendor_class"
pattern = "MSFT 5.0"
action = "custom_options"
option_set = "windows_clients"
```

**Custom Options** (`dhcp_options.toml`):
```toml
[[option_sets]]
name = "windows_clients"
scope = "acl"

[[option_sets.options]]
code = 42  # NTP servers
type = "ip_list"
value = ["192.168.1.10", "192.168.1.11"]

[[option_sets.options]]
code = 66  # TFTP server with template
type = "string"
value = "tftp-${pool_name}.local"
```

---

## Functional Requirements

### FR1: Pool Management

- **FR1.1**: Load pool definitions from TOML on service start
- **FR1.2**: Validate pool configurations (CIDR validity, range overlaps)
- **FR1.3**: Dynamic pool enable/disable without service restart
- **FR1.4**: Pool utilization monitoring (allocated/available addresses)
- **FR1.5**: Automatic pool selection based on relay agent subnet or client matching
- **FR1.6**: Enforce max_leases limit per pool (default 1000)

### FR2: Lease Lifecycle

- **FR2.1**: Persist lease on DISCOVER→OFFER→REQUEST→ACK (v4) or SOLICIT→ADVERTISE→REQUEST→REPLY (v6)
- **FR2.2**: Lease renewal updates expiration times
- **FR2.3**: Automatic lease expiration cleanup via GenServer worker
- **FR2.4**: **Conflict Resolution**: On DECLINE/duplicate detection:
  - Automatically reassign new address from pool
  - Log warning with client identifier and conflicted address
  - Increment conflict counter on lease record
  - Mark conflicted address as temporarily unavailable (configurable quarantine period)
- **FR2.5**: Manual lease revocation via management API

### FR3: ACL Enforcement

- **FR3.1**: Evaluate ACL rules in priority order (lowest first)
- **FR3.2**: First matching rule determines action
- **FR3.3**: No-match defaults to configurable policy (allow/deny)
- **FR3.4**: ACL-based pool assignment overrides default selection
- **FR3.5**: ACL rule hot-reload without service interruption

### FR4: Custom Options

- **FR4.1**: Apply option sets based on scope hierarchy:
  1. Static reservation options
  2. ACL-matched option sets
  3. Pool-level options
  4. Global options
- **FR4.2**: Option merging strategy (override vs. append for multi-value options)
- **FR4.3**: **Simple template substitution**:
  - Variable format: `${variable_name}`
  - Supported variables: `client_mac`, `client_duid`, `client_hostname`, `lease_address`, `pool_name`
  - No expression evaluation, no conditionals
  - Missing variables replaced with empty string
- **FR4.4**: Validation of option data types before encoding

### FR5: Data Persistence

- **FR5.1**: Atomic lease writes (no partial state)
- **FR5.2**: Crash recovery restores last consistent state
- **FR5.3**: Configurable snapshot interval for ETS backend
- **FR5.4**: Lease database compaction (remove expired entries)
- **FR5.5**: Export/import for YellowDog TOML format only (no ISC DHCP compatibility)

---

## Non-Functional Requirements

### NFR1: Performance

- Lease allocation: <1ms (ETS/DETS), <5ms (external DB)
- Support 1000 active leases per pool (configurable up to 10,000)
- ACL evaluation: <100μs for typical rule sets (<100 rules)
- Conflict reassignment: <10ms total (detection + new allocation)

### NFR2: Reliability

- No lease state loss on clean shutdown
- Automatic recovery from corrupted DETS files (fallback to last snapshot)
- Lease expiration worker must not block service operations
- Conflict reassignment failures trigger alert but don't block service

### NFR3: Observability

- Telemetry events for:
  - Lease allocations, renewals, releases
  - Pool utilization changes
  - ACL match/deny events
  - Backend write latency
  - **Conflict detection and reassignment**
  - **Pool limit exceeded events**
- Warning logs for:
  - Address conflicts with client identifier and reassigned address
  - Pool approaching capacity (>90%)
  - Repeated conflicts from same client (>3 per hour)

### NFR4: Configuration

- TOML schema validation on load
- Clear error messages for misconfiguration
- Support for configuration file includes (modular organization)
- Live reload for ACL/option changes (pools require restart)

---

## Integration Points

### With YellowDog.Telemetry

- Emit structured events for lease lifecycle
- Track pool utilization metrics
- Record ACL evaluation statistics
- Alert on conflict patterns

### With ex_dhcp

- Persistence layer provides callbacks for:
  - Address availability check
  - Lease creation/renewal
  - Option generation based on client context
- Receive parsed request packets, return option lists
- Handle DECLINE messages for conflict resolution

### With Core YellowDog Application

- Configuration loading from centralized TOML
- Supervised GenServers for lease management
- Management API endpoints (future Phoenix dashboard)

---

## Success Metrics

- **Lease Consistency**: 0% lease loss across service restarts
- **ACL Performance**: 99.9th percentile evaluation time <500μs
- **Pool Utilization**: Accurate reporting within 1% margin
- **Configuration Errors**: 100% caught at validation time, not runtime
- **Conflict Resolution**: Automatic reassignment in <10ms, 0% service disruption
- **Pool Limits**: Hard enforcement, no overallocation

---

## Design Decisions

### 1. Lease Database Size Limits
**Decision**: Default max 1000 leases per pool, configurable per-pool override  
**Rationale**: Targets small-to-medium deployments, prevents runaway allocation

### 2. Conflict Resolution Strategy
**Decision**: Automatic reassignment with warning logs  
**Rationale**: Maintains service availability, provides audit trail for investigation

### 3. Template Variable Complexity
**Decision**: Simple `${var}` substitution only  
**Rationale**: Covers 95% of use cases, avoids security/complexity of expression languages

### 4. Configuration Migration
**Decision**: YellowDog TOML format only, no ISC DHCP import  
**Rationale**: Clean-slate design, users migrate via manual translation or scripts

---

## Future Considerations

- **Clustering**: Mnesia backend for multi-node deployments
- **Lease History**: Audit trail for compliance requirements
- **IPAM Integration**: External IP address management system sync
- **Prefix Delegation**: Advanced DHCPv6 IA_PD with route injection
- **Dynamic DNS Updates**: RFC 4704 (v6) and RFC 4702 (v4) support
- **Conflict Quarantine**: Configurable hold-down timer for conflicted addresses

