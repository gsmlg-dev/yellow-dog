# Domain Model: DNS Zone Editor

## Core Entities

### 1. Zone (Aggregate Root)

```elixir
%YellowDog.Dns.Zone.Auth{
  # Identity
  name: "example.com",              # Zone name (domain)

  # Storage
  table: #Reference<...>,           # ETS table reference

  # Required Records
  soa: %DNS.Message.Record{         # SOA record (exactly one)
    name: "example.com",
    type: :soa,
    class: :in,
    ttl: 86400,
    rdata: %{
      mname: "ns1.example.com",     # Primary nameserver
      rname: "admin.example.com",   # Admin email (@ → .)
      serial: 2026011301,           # YYYYMMDDnn format
      refresh: 7200,                # Secondary refresh interval
      retry: 3600,                  # Retry on failed refresh
      expire: 1209600,              # Zone expiration time
      minimum: 3600                 # Negative caching TTL
    }
  },
  ns_records: [%DNS.Message.Record{...}],  # NS records at apex

  # Persistence
  zone_file: "/var/dns/zones/example.com.zone",
  zone_data_path: "/var/dns/zones",

  # Configuration
  ttl: 3600,                        # Default TTL

  # Runtime State
  created_at: ~U[2026-01-13 00:00:00Z],
  query_count: 15420,
  hit_count: 14890,
  miss_count: 530,
  dirty: false,                     # Has unsaved changes

  # NEW: Optimistic Locking
  version: 42                       # Incremented on each change
}
```

### 2. Resource Record

```elixir
%DNS.Message.Record{
  # Identity
  name: "www.example.com",          # Record name (FQDN or relative)
  type: :a,                         # Record type atom
  class: :in,                       # Record class (almost always :in)

  # Data
  ttl: 3600,                        # Time to live in seconds
  rdata: {192, 0, 2, 1},            # Type-specific data

  # NEW: Metadata for editing
  version: 1,                       # Record version for optimistic locking
  created_at: ~U[2026-01-13 10:30:00Z],
  updated_at: ~U[2026-01-13 10:30:00Z]
}
```

### 3. Supported Record Types and RDATA Formats

| Type | RDATA Format | Example | Validation |
|------|-------------|---------|------------|
| A | `{a, b, c, d}` | `{192, 0, 2, 1}` | IPv4 octets 0-255 |
| AAAA | `{a,b,c,d,e,f,g,h}` | `{0x2001, 0xdb8, ...}` | IPv6 16-bit segments |
| CNAME | `"target.domain."` | `"www.other.com."` | Valid domain, FQDN |
| MX | `{priority, "host"}` | `{10, "mail.example.com."}` | Priority 0-65535 |
| NS | `"nameserver.domain."` | `"ns1.example.com."` | Valid domain |
| TXT | `"text data"` or `["a", "b"]` | `"v=spf1 ..."` | Max 255 chars/string |
| SRV | `{priority, weight, port, "target"}` | `{0, 5, 443, "server."}` | Ports 0-65535 |
| PTR | `"target.domain."` | `"host.example.com."` | Valid domain |
| CAA | `{flags, "tag", "value"}` | `{0, "issue", "ca.com"}` | Tag: issue/issuewild/iodef |
| SOA | See SOA struct above | | Required fields |

### 4. Change History Entry (NEW)

```elixir
%YellowDog.Dns.Zone.History.Entry{
  # Identity
  id: "chg_01HQB...",               # ULID
  zone_name: "example.com",

  # Change Details
  action: :create | :update | :delete,
  record_type: :a,
  record_name: "www.example.com",

  # Before/After State
  before: nil | %DNS.Message.Record{},
  after: nil | %DNS.Message.Record{},

  # Audit
  timestamp: ~U[2026-01-13 10:30:00Z],
  user_id: "usr_01HQB...",          # Optional: if auth enabled
  ip_address: "192.168.1.100",      # Request source

  # Rollback Support
  reversible: true,
  reverted: false
}
```

### 5. Validation Result

```elixir
%DNS.Zone.ValidationResult{
  valid: false,

  errors: [
    %{
      severity: :error,
      code: :cname_conflict,
      message: "CNAME at www.example.com conflicts with existing A record",
      record_name: "www.example.com",
      record_type: :cname,
      conflicting_type: :a
    }
  ],

  warnings: [
    %{
      severity: :warning,
      code: :orphaned_mx,
      message: "MX target mail.example.com has no A/AAAA record",
      record_name: "example.com",
      record_type: :mx,
      missing_target: "mail.example.com"
    }
  ],

  info: [
    %{
      severity: :info,
      code: :single_ns,
      message: "Zone has only 1 NS record, recommend at least 2"
    }
  ]
}
```

## Entity Relationships

```
┌─────────────────────────────────────────────────────────────┐
│                        Zone (Auth)                          │
│                                                             │
│  name: "example.com"                                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  Required Records                    │   │
│  │                                                       │   │
│  │  SOA (exactly 1)    NS (1..n)                        │   │
│  │  ┌──────────────┐   ┌──────────────┐                 │   │
│  │  │ @ SOA ...    │   │ @ NS ns1     │                 │   │
│  │  └──────────────┘   │ @ NS ns2     │                 │   │
│  │                     └──────────────┘                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  ETS Table (records)                 │   │
│  │                                                       │   │
│  │  {("www", :a)}      → [Record, Record]              │   │
│  │  {("www", :aaaa)}   → [Record]                      │   │
│  │  {("mail", :a)}     → [Record]                      │   │
│  │  {("", :mx)}        → [Record, Record]              │   │
│  │  {("api", :cname)}  → [Record]                      │   │
│  │                                                       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  Change History (ring buffer)        │   │
│  │                                                       │   │
│  │  [Entry, Entry, Entry, ...]  (max 1000 entries)     │   │
│  │                                                       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## State Machines

### Zone State

```
                    ┌─────────────┐
                    │   Loading   │
                    └──────┬──────┘
                           │ zone_loaded
                           ▼
      ┌─────────────────────────────────────┐
      │                                     │
      │            ┌─────────┐              │
      │      ┌────>│  Clean  │<────┐       │
      │      │     └────┬────┘     │       │
      │      │          │          │       │
      │   save()     add/update/  save()   │
      │      │       delete        │       │
      │      │          │          │       │
      │      │     ┌────▼────┐     │       │
      │      └─────│  Dirty  │─────┘       │
      │            └─────────┘             │
      │                                     │
      │             Running                 │
      └─────────────────────────────────────┘
                       │
                  stop/shutdown
                       │
                       ▼
              ┌─────────────────┐
              │   Terminating   │
              │  (auto-save if  │
              │     dirty)      │
              └─────────────────┘
```

### Record Lifecycle

```
                    ┌──────────┐
        create()    │  Draft   │  (in form, not yet saved)
           │        └────┬─────┘
           │             │ submit + validate
           │             ▼
           │      ┌──────────────┐
           └─────>│   Active     │<────────────────┐
                  └──────┬───────┘                 │
                         │                         │
            ┌────────────┼────────────┐            │
            │            │            │            │
        update()     delete()     restore()        │
            │            │            │            │
            │            ▼            │            │
            │     ┌──────────┐        │            │
            │     │ Deleted  │────────┘            │
            │     │(in history)                    │
            │     └──────────┘                     │
            │                                      │
            └──────────────────────────────────────┘
```

## Invariants

### Zone Invariants

1. **SOA Required**: Zone must have exactly one SOA record at apex
2. **NS Required**: Zone must have at least one NS record at apex
3. **Serial Increment**: SOA serial must increase on any change
4. **TTL Consistency**: Records in same RRSet must have identical TTLs
5. **Name Scope**: All records must be within zone (end with zone name)

### Record Invariants

1. **CNAME Exclusivity**: If CNAME exists at name, no other types allowed
2. **No CNAME at Apex**: Zone apex cannot have CNAME (conflicts with SOA/NS)
3. **MX/NS Not CNAME**: MX and NS targets must not point to CNAMEs
4. **Valid TTL Range**: TTL must be 0 to 2,147,483,647 seconds
5. **Valid Domain Names**: Labels max 63 chars, total max 255 chars

### Type-Specific Invariants

| Type | Invariant |
|------|-----------|
| A | IPv4 address octets 0-255 |
| AAAA | Valid IPv6 address |
| MX | Priority 0-65535, target is valid domain |
| SRV | All numeric fields 0-65535, target valid domain |
| TXT | Each string max 255 bytes |
| CAA | Tag is "issue", "issuewild", or "iodef" |

## Use Cases

### UC1: Add A Record

```elixir
# Input
%{
  name: "www",                      # Relative to zone origin
  type: :a,
  ttl: 3600,
  rdata: "192.0.2.1"               # User enters as string
}

# Processing
1. Parse rdata string → {192, 0, 2, 1}
2. Expand name: "www" + "example.com" → "www.example.com"
3. Validate: IPv4 format, TTL range
4. Check zone rules: No CNAME conflict
5. Insert into ETS
6. Increment zone version
7. Mark zone dirty
8. Log change
9. Publish event

# Output
{:ok, %DNS.Message.Record{
  name: "www.example.com",
  type: :a,
  class: :in,
  ttl: 3600,
  rdata: {192, 0, 2, 1},
  version: 1
}}
```

### UC2: Add MX Record

```elixir
# Input
%{
  name: "",                         # @ (apex)
  type: :mx,
  ttl: 3600,
  priority: 10,
  target: "mail.example.com"
}

# Processing
1. Expand name: "" → "example.com" (apex)
2. Parse rdata: {10, "mail.example.com."}
3. Validate: Priority range, target is FQDN
4. Check zone rules:
   - No CNAME at apex ✓
   - Target is not a CNAME (warning if can't verify)
5. Insert into ETS
6. Log + publish

# Output
{:ok, %DNS.Message.Record{
  name: "example.com",
  type: :mx,
  class: :in,
  ttl: 3600,
  rdata: {10, "mail.example.com."}
}}
```

### UC3: Import Zone File

```elixir
# Input
"""
$TTL 3600
$ORIGIN example.com.
@    IN  SOA   ns1 admin (2026011301 7200 3600 1209600 3600)
@    IN  NS    ns1
@    IN  NS    ns2
ns1  IN  A     192.0.2.1
ns2  IN  A     192.0.2.2
www  IN  A     192.0.2.10
mail IN  A     192.0.2.20
@    IN  MX 10 mail
"""

# Processing
1. Parse directives: $TTL, $ORIGIN
2. Parse records line by line
3. Validate each record individually
4. Validate zone-wide rules
5. Generate preview with any warnings
6. User confirms
7. Bulk insert all records
8. Update SOA with new serial
9. Log import event

# Output
{:ok, %{
  records_added: 8,
  warnings: [
    %{message: "MX target 'mail' should be FQDN 'mail.example.com.'"}
  ]
}}
```

### UC4: Detect CNAME Conflict

```elixir
# Existing record
%DNS.Message.Record{name: "www.example.com", type: :a, rdata: {192, 0, 2, 1}}

# Attempted add
%{name: "www", type: :cname, rdata: "other.example.com."}

# Processing
1. Expand name: "www.example.com"
2. Check existing records at name
3. Found: A record exists
4. Rule: CNAME cannot coexist with other types

# Output
{:error, %{
  code: :cname_conflict,
  message: "Cannot add CNAME at www.example.com: A record already exists",
  existing_types: [:a]
}}
```

### UC5: Validate Zone

```elixir
# Zone has these issues:
# - MX target "mail.example.com" has no A record
# - Only 1 NS record
# - www has both A and CNAME (conflict)

# Output
%DNS.Zone.ValidationResult{
  valid: false,

  errors: [
    %{
      severity: :error,
      code: :cname_conflict,
      message: "CNAME at www.example.com conflicts with A record",
      record_name: "www.example.com"
    }
  ],

  warnings: [
    %{
      severity: :warning,
      code: :orphaned_mx_target,
      message: "MX target mail.example.com has no A/AAAA record in zone"
    },
    %{
      severity: :warning,
      code: :single_ns,
      message: "Zone has only 1 NS record; recommend at least 2 for redundancy"
    }
  ]
}
```

## Query Patterns

### Most Common Operations

| Operation | ETS Pattern | Performance |
|-----------|-------------|-------------|
| Get record by name+type | `lookup(table, {name, type})` | O(1) |
| Get all records for name | `match(table, {{name, :_}, :_})` | O(n) |
| Get all records | `tab2list(table)` | O(n) |
| Check name exists | `match(table, {{name, :_}, :_})` | O(n) |
| Count by type | `select_count(table, ...)` | O(n) |

### Index Recommendations

Since we use ETS with composite keys `{name, type}`:
- Lookups by name+type are O(1)
- Lookups by name only require table scan
- Consider secondary index for type-only queries if needed
