# DNS Zone Editor Feature

**Version:** 1.0
**Status:** Architecture Complete
**Last Updated:** 2026-01-13

## Overview

The DNS Zone Editor is a comprehensive web-based interface for managing authoritative DNS zones in YellowDog DNS. It provides real-time record management, zone file import/export, validation, and DNSSEC operations through Phoenix LiveView.

## Goals

1. **Complete Zone Management** - Full CRUD for DNS records with type-specific validation
2. **Bulk Operations** - Import/export zones in BIND format, batch record modifications
3. **RFC Compliance** - Validate zones against DNS RFCs (1035, 2181, 2308, etc.)
4. **Real-time Collaboration** - Live updates with optimistic locking for concurrent edits
5. **Audit Trail** - Track all changes with user attribution and rollback capability

## Architecture

```
apps/
├── ex_dns/                     # DNS protocol library (existing)
│   └── lib/dns/zone/
│       ├── validator.ex        # Enhanced validation logic
│       ├── editor.ex           # Zone editing API
│       └── file_parser.ex      # BIND format parser
│
├── yellow_dog_dns/             # DNS server application
│   └── lib/yellow_dog/dns/
│       ├── zone/
│       │   ├── auth.ex         # Auth zone (enhanced)
│       │   └── history.ex      # NEW: Change history
│       └── boundaries/
│           └── zone_service.ex # NEW: Service orchestration
│
└── yellow_dog_console/         # Web console
    └── lib/yellow_dog/console/
        └── live/dns_live/
            ├── rr_live/
            │   ├── index.ex    # Enhanced record list
            │   ├── form.ex     # NEW: Type-specific forms
            │   └── bulk.ex     # NEW: Bulk operations
            └── zone_live/
                ├── import.ex   # NEW: Zone import wizard
                └── export.ex   # NEW: Zone export
```

## Key Features

### Phase 1: Core Editor (Week 1-2)
- [x] Record list with filtering
- [ ] Type-specific record forms with validation
- [ ] Real-time validation feedback
- [ ] Optimistic locking for concurrent edits

### Phase 2: Bulk Operations (Week 3-4)
- [ ] BIND zone file import with preview
- [ ] Zone file export
- [ ] Batch TTL updates
- [ ] Copy/duplicate records

### Phase 3: Advanced Features (Week 5-6)
- [ ] Change history and audit trail
- [ ] Rollback capability
- [ ] Zone validation report
- [ ] Search and replace

### Phase 4: DNSSEC (Future)
- [ ] DNSSEC key management
- [ ] Zone signing
- [ ] DS record generation

## Tech Stack

- **Elixir 1.18+** with OTP 27+
- **Phoenix 1.8** with LiveView 1.0
- **DaisyUI 5.0** for UI components
- **ETS** for zone storage (existing)
- **ex_dns** for DNS protocol handling

## Documentation Index

| File | Purpose |
|------|---------|
| [architecture/00_SYSTEM_OVERVIEW.md](architecture/00_SYSTEM_OVERVIEW.md) | High-level design |
| [architecture/01_DOMAIN_MODEL.md](architecture/01_DOMAIN_MODEL.md) | Entities and relationships |
| [architecture/02_DATA_LAYER.md](architecture/02_DATA_LAYER.md) | Storage and persistence |
| [architecture/03_FUNCTIONAL_CORE.md](architecture/03_FUNCTIONAL_CORE.md) | Pure validation logic |
| [architecture/04_BOUNDARIES.md](architecture/04_BOUNDARIES.md) | Service orchestration |
| [architecture/05_LIVEVIEW_COMPONENTS.md](architecture/05_LIVEVIEW_COMPONENTS.md) | UI components |
| [decisions/ADR-001-storage-strategy.md](decisions/ADR-001-storage-strategy.md) | ETS vs PostgreSQL |
| [decisions/ADR-002-validation-approach.md](decisions/ADR-002-validation-approach.md) | Validation architecture |
| [decisions/ADR-003-change-tracking.md](decisions/ADR-003-change-tracking.md) | Audit trail design |
| [guardrails/NEVER_DO.md](guardrails/NEVER_DO.md) | Critical prohibitions |
| [guardrails/ALWAYS_DO.md](guardrails/ALWAYS_DO.md) | Mandatory practices |

## Quick Start

```elixir
# Get zone records
records = YellowDog.Dns.Zone.Auth.get_all_records(zone_pid)

# Add record with validation
{:ok, record} = YellowDog.Dns.Boundaries.ZoneService.add_record(
  zone_pid,
  %{name: "www.example.com", type: :a, ttl: 3600, rdata: {192, 0, 2, 1}}
)

# Validate entire zone
{:ok, report} = DNS.Zone.Validator.validate(zone)

# Import zone file
{:ok, records} = DNS.Zone.FileParser.parse(file_content, origin: "example.com")
```

## Related Documentation

- [CLAUDE.md](../../../CLAUDE.md) - Project conventions
- [ex_dns/CLAUDE.md](../../../apps/ex_dns/CLAUDE.md) - DNS library guide
- [RFC 1035](https://tools.ietf.org/html/rfc1035) - DNS specification
- [RFC 2181](https://tools.ietf.org/html/rfc2181) - DNS clarifications
