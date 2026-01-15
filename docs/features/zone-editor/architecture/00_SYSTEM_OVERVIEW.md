# System Overview: DNS Zone Editor

## Vision

Provide a production-grade DNS zone editor that enables administrators to manage authoritative zones with confidence through comprehensive validation, real-time feedback, and complete audit trails.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Web Console (Phoenix LiveView)                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │   ViewLive       │  │   ZoneLive       │  │   RrLive             │  │
│  │   /dns/views     │→→│   /dns/.../zones │→→│   /dns/.../records   │  │
│  │                  │  │                  │  │                      │  │
│  │  - List views    │  │  - List zones    │  │  - List records      │  │
│  │  - Create/Edit   │  │  - Import zone   │  │  - Type-specific     │  │
│  │  - ACL config    │  │  - Export zone   │  │    forms             │  │
│  └──────────────────┘  └──────────────────┘  │  - Bulk operations   │  │
│                                              │  - Validation        │  │
│                                              └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Boundaries Layer (Service Orchestration)            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    ZoneService (Ecto.Multi)                        │ │
│  │                                                                    │ │
│  │  add_record/2        - Validate → Insert → Log → Publish          │ │
│  │  update_record/3     - Load → Validate → Update → Log → Publish   │ │
│  │  delete_record/2     - Load → Validate → Delete → Log → Publish   │ │
│  │  import_zone/2       - Parse → Validate → Bulk Insert → Log       │ │
│  │  export_zone/2       - Load → Format → Return                     │ │
│  │  validate_zone/1     - Load all → Validate rules → Report         │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Functional Core (Pure Functions)                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐   │
│  │ RecordValidator   │  │ ZoneValidator     │  │ FileParser        │   │
│  │                   │  │                   │  │                   │   │
│  │ - validate_a/1    │  │ - validate_soa/1  │  │ - parse_line/2    │   │
│  │ - validate_aaaa/1 │  │ - validate_ns/1   │  │ - parse_record/2  │   │
│  │ - validate_mx/1   │  │ - check_cname/1   │  │ - parse_rdata/2   │   │
│  │ - validate_txt/1  │  │ - check_rrset/1   │  │ - format_bind/1   │   │
│  │ - validate_srv/1  │  │ - check_refs/1    │  │ - format_json/1   │   │
│  │ - validate_cname/1│  │                   │  │                   │   │
│  └───────────────────┘  └───────────────────┘  └───────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Data Layer (Storage)                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Auth Zone (GenServer + ETS)                     │ │
│  │                                                                    │ │
│  │  State:                        ETS Table (per zone):               │ │
│  │  ┌─────────────────────┐      ┌─────────────────────────────────┐ │ │
│  │  │ name: "example.com" │      │ Key: {name, type}               │ │ │
│  │  │ table: :ets_ref     │      │ Val: %{name, type, class, ttl,  │ │ │
│  │  │ soa: %Record{}      │      │       rdata, version}           │ │ │
│  │  │ ns_records: [...]   │      │                                 │ │ │
│  │  │ zone_file: path     │      │ ("www", :a) → record            │ │ │
│  │  │ dirty: boolean      │      │ ("www", :aaaa) → record         │ │ │
│  │  │ version: integer    │      │ ("mail", :a) → record           │ │ │
│  │  └─────────────────────┘      └─────────────────────────────────┘ │ │
│  │                                                                    │ │
│  │  Operations:                                                       │ │
│  │  - add_record/2      → :ets.insert with version                   │ │
│  │  - get_records/3     → :ets.lookup                                │ │
│  │  - get_all_records/1 → :ets.tab2list                              │ │
│  │  - remove_record/3   → :ets.delete                                │ │
│  │  - save/1            → Zone.Loader.save_zone_to_file              │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Zone File Persistence                           │ │
│  │                                                                    │ │
│  │  Load: Zone.Loader.load_zone_from_file/2 → parse → ETS            │ │
│  │  Save: ETS → Zone struct → Zone.Loader.save_zone_to_file/2        │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Change History (NEW)                            │ │
│  │                                                                    │ │
│  │  - In-memory ring buffer per zone (configurable size)             │ │
│  │  - Persisted to zone file as comments on save                     │ │
│  │  - Entries: {timestamp, action, record_before, record_after}      │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Event Publishing                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Phoenix.PubSub broadcasts on zone changes:                             │
│                                                                          │
│  Topic: "zone:example.com"                                              │
│  Events:                                                                 │
│    - {:record_added, record}                                            │
│    - {:record_updated, old_record, new_record}                          │
│    - {:record_deleted, record}                                          │
│    - {:zone_imported, count}                                            │
│    - {:zone_saved}                                                      │
│                                                                          │
│  Subscribers:                                                            │
│    - LiveView processes (real-time UI updates)                          │
│    - Zone transfer handlers (NOTIFY)                                    │
│    - Audit logger                                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

### 1. LiveView Layer (Presentation)

| Component | Responsibility |
|-----------|----------------|
| `RrLive.Index` | Record listing, filtering, pagination |
| `RrLive.Form` | Type-specific record forms with live validation |
| `RrLive.Bulk` | Bulk operations modal (import, batch update) |
| `ZoneLive.Import` | Zone file import wizard with preview |
| `ZoneLive.Export` | Zone export with format selection |

### 2. Boundaries Layer (Orchestration)

| Component | Responsibility |
|-----------|----------------|
| `ZoneService` | Coordinate multi-step operations atomically |
| | - Validation before mutations |
| | - Change logging |
| | - Event publishing |
| | - Optimistic locking |

### 3. Functional Core (Business Logic)

| Component | Responsibility |
|-----------|----------------|
| `RecordValidator` | Per-record-type validation rules |
| `ZoneValidator` | Zone-wide validation (CNAME conflicts, orphans) |
| `FileParser` | BIND zone file parsing and formatting |
| `RdataParser` | Type-specific rdata parsing |

### 4. Data Layer (Storage)

| Component | Responsibility |
|-----------|----------------|
| `Auth` (GenServer) | Zone lifecycle, ETS management |
| Zone files | Persistent storage in BIND format |
| Change history | In-memory with optional persistence |

## Data Flow: Add Record

```
User                  LiveView             Service            Validator           Auth Zone
  │                      │                    │                   │                   │
  │ Submit form          │                    │                   │                   │
  ├─────────────────────>│                    │                   │                   │
  │                      │ add_record(params) │                   │                   │
  │                      ├───────────────────>│                   │                   │
  │                      │                    │ validate_record   │                   │
  │                      │                    ├──────────────────>│                   │
  │                      │                    │<─────────────────┤                   │
  │                      │                    │ {:ok, valid}      │                   │
  │                      │                    │                   │                   │
  │                      │                    │ validate_zone_rules                   │
  │                      │                    ├──────────────────>│                   │
  │                      │                    │<─────────────────┤                   │
  │                      │                    │ {:ok, no_conflicts}                   │
  │                      │                    │                   │                   │
  │                      │                    │ Auth.add_record   │                   │
  │                      │                    ├──────────────────────────────────────>│
  │                      │                    │<─────────────────────────────────────┤
  │                      │                    │ :ok               │                   │
  │                      │                    │                   │                   │
  │                      │                    │ log_change        │                   │
  │                      │                    │ publish_event     │                   │
  │                      │                    │                   │                   │
  │                      │<──────────────────┤                   │                   │
  │                      │ {:ok, record}      │                   │                   │
  │                      │                    │                   │                   │
  │ UI updates via PubSub│                    │                   │                   │
  │<─────────────────────│                    │                   │                   │
  │                      │                    │                   │                   │
```

## Security Considerations

### Input Validation
- All record data validated before storage
- Domain name syntax checked (RFC 1035)
- IP addresses validated for A/AAAA records
- Zone file content sanitized on import

### Authorization
- Zone-level permissions (view, edit, admin)
- Action audit trail
- Concurrent edit detection (optimistic locking)

### Data Protection
- No sensitive data in DNS records by design
- Audit logs do not contain credentials
- Zone files stored with appropriate permissions

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Record lookup | <1ms | ETS read_concurrency |
| Add record | <10ms | Including validation |
| Import 1000 records | <2s | Bulk insert |
| Zone validation | <500ms | For zones up to 10K records |
| LiveView response | <50ms | User interaction feedback |

## Error Handling Strategy

### Validation Errors
- Returned as structured data with field paths
- Displayed inline in forms
- Collected for bulk operations

### System Errors
- Logged with telemetry
- User-friendly messages displayed
- Operations are atomic (no partial commits)

### Conflict Resolution
- Optimistic locking prevents lost updates
- Version mismatch triggers reload prompt
- PubSub notifies of concurrent changes

## Scalability

### Current Design Limits
- Single-node ETS storage (no clustering)
- In-memory zones (memory-bound)
- Suitable for zones up to 100K records

### Future Considerations
- Zone sharding across nodes
- PostgreSQL backend option
- Redis caching layer
