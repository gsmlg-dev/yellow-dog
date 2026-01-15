# Implementation Plan: DNS Zone Editor

## Overview

This plan breaks the zone editor feature into phases with specific tasks. Each task should take 15-60 minutes to implement.

## Prerequisites

Before starting:
- [x] Read architecture documents in `docs/features/zone-editor/architecture/`
- [x] Understand existing Auth zone in `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex`
- [x] Review existing RrLive pages in `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/`

---

## Phase 1: Record Validation Core (Week 1)

### Task 1.1: Create RecordValidator Module
**Time:** 45 min
**Location:** `apps/ex_dns/lib/dns/zone/validator/record.ex`

Create the pure validation module with:
- `validate_a/1` - IPv4 validation
- `validate_aaaa/1` - IPv6 validation
- `validate_cname/1` - CNAME validation
- `validate_mx/1` - MX validation with priority
- `validate_txt/1` - TXT validation
- `validate_srv/1` - SRV validation
- `validate_ns/1` - NS validation
- `validate/2` - Dispatcher function

Reference: `docs/features/zone-editor/architecture/03_FUNCTIONAL_CORE.md`

### Task 1.2: Create RecordValidator Tests
**Time:** 30 min
**Location:** `apps/ex_dns/test/dns/zone/validator/record_test.exs`

Write tests for each record type covering:
- Valid inputs
- Invalid inputs
- Edge cases (empty fields, max values)

### Task 1.3: Create ZoneValidator Module
**Time:** 45 min
**Location:** `apps/ex_dns/lib/dns/zone/validator/zone.ex`

Implement zone-wide validation:
- `check_would_conflict/3` - CNAME conflict detection
- `validate/2` - Full zone validation
- SOA/NS required checks
- TTL consistency checks

Reference: `docs/features/zone-editor/architecture/03_FUNCTIONAL_CORE.md`

### Task 1.4: Create ZoneValidator Tests
**Time:** 30 min
**Location:** `apps/ex_dns/test/dns/zone/validator/zone_test.exs`

Test zone validation rules:
- CNAME conflicts
- CNAME at apex blocked
- Missing SOA/NS detection
- TTL mismatch warnings

---

## Phase 2: Service Layer (Week 1-2)

### Task 2.1: Create ZoneService Module
**Time:** 60 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Implement service orchestration:
- `add_record/3` - Validate → Insert → Log → Publish
- `update_record/6` - Load → Validate → Update → Log
- `delete_record/5` - Load → Validate → Delete → Log
- `validate_zone/1` - Full zone validation report

Reference: `docs/features/zone-editor/architecture/04_BOUNDARIES.md`

### Task 2.2: Add Version Metadata to Auth Zone
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex`

Enhance record storage with metadata:
- Add `zone_version` to state struct
- Store `{record, metadata}` tuples in ETS
- Update `add_record` to initialize version
- Add `update_record_with_version/4` callback

### Task 2.3: Create ZoneService Tests
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/test/yellow_dog/dns/boundaries/zone_service_test.exs`

Test service layer:
- Record CRUD operations
- Validation error handling
- Version conflict detection
- PubSub event publishing

---

## Phase 3: Enhanced LiveView Forms (Week 2)

### Task 3.1: Create Type-Specific Form Component
**Time:** 60 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/form_component.ex`

Build dynamic form that changes based on record type:
- Common fields (name, TTL)
- Type-specific fields (IP, priority, target, etc.)
- Real-time validation feedback
- Version field for optimistic locking

### Task 3.2: Update Index LiveView for New Form
**Time:** 30 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`

Integrate new form component:
- Handle "new" action with type selection
- Handle "edit" action with existing record
- Display validation errors
- Handle version conflicts

### Task 3.3: Add PubSub Subscriptions
**Time:** 30 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`

Enable real-time updates:
- Subscribe to `zone:{zone_name}` topic on mount
- Handle `:record_added` - insert into stream
- Handle `:record_updated` - update in stream
- Handle `:record_deleted` - remove from stream

---

## Phase 4: Zone Import (Week 3)

### Task 4.1: Create BIND Parser Module
**Time:** 60 min
**Location:** `apps/ex_dns/lib/dns/zone/parser/bind.ex`

Implement zone file parsing:
- Parse $ORIGIN, $TTL directives
- Parse resource records
- Handle multi-line records (parentheses)
- Return structured records or errors

Reference: `docs/features/zone-editor/architecture/03_FUNCTIONAL_CORE.md`

### Task 4.2: Create Parser Tests
**Time:** 30 min
**Location:** `apps/ex_dns/test/dns/zone/parser/bind_test.exs`

Test zone file parsing:
- Valid zone files
- Various record types
- Directive handling
- Error reporting

### Task 4.3: Create Import Service
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Add import functionality to ZoneService:
- `import_zone_file/3` - Parse → Validate → Preview → Import
- Support preview mode (validation only)
- Return import report with warnings

### Task 4.4: Create Import LiveView
**Time:** 60 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/import_live.ex`

Build import wizard:
- File upload or paste textarea
- Preview parsed records
- Show validation warnings
- Confirm and import button

---

## Phase 5: Zone Export (Week 3)

### Task 5.1: Create Zone Formatter Module
**Time:** 45 min
**Location:** `apps/ex_dns/lib/dns/zone/formatter.ex`

Implement zone export:
- `to_bind/2` - Format as BIND zone file
- `to_json/2` - Format as JSON
- Proper escaping and formatting

### Task 5.2: Add Export to ZoneService
**Time:** 20 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Add `export_zone/2` function:
- Load all records
- Format with specified formatter
- Return content string

### Task 5.3: Create Export UI
**Time:** 30 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex`

Add export button/modal:
- Format selection dropdown
- Download as file
- Copy to clipboard option

---

## Phase 6: Batch Operations (Week 4)

### Task 6.1: Add Batch TTL Update
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Implement `batch_update_ttl/4`:
- Filter records by criteria
- Update TTL for matching records
- Log changes
- Return count

### Task 6.2: Add Batch Delete
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Implement `batch_delete/3`:
- Filter records by criteria
- Check deletion rules (can't delete required records)
- Delete matching records
- Return count

### Task 6.3: Create Bulk Operations UI
**Time:** 60 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/bulk_component.ex`

Build bulk operations modal:
- Select operation (update TTL, delete)
- Filter criteria (name pattern, type)
- Preview affected records
- Confirm and execute

---

## Phase 7: Change History (Week 4)

### Task 7.1: Create History Module
**Time:** 45 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/history.ex`

Implement change tracking:
- `Entry` struct with before/after snapshots
- Ring buffer storage (max 1000 entries)
- `add_entry/2`, `get_recent/2`, `find_entry/2`

### Task 7.2: Integrate History with ZoneService
**Time:** 30 min
**Location:** `apps/yellow_dog_dns/lib/yellow_dog/dns/boundaries/zone_service.ex`

Add history logging to all mutations:
- Log create/update/delete actions
- Include metadata (timestamp)

### Task 7.3: Create History View
**Time:** 45 min
**Location:** `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/history_live.ex`

Display change history:
- Chronological list of changes
- Before/after diff view
- Filter by record name/type
- (Future: Rollback button)

---

## Testing Checklist

After each phase, verify:

- [ ] All new code has tests
- [ ] Tests pass: `mix test apps/ex_dns && mix test apps/yellow_dog_dns`
- [ ] No warnings: `mix compile --warnings-as-errors`
- [ ] Formatted: `mix format`
- [ ] Credo clean: `mix credo --strict`

---

## Definition of Done

Feature is complete when:

1. ✅ Records can be added/edited/deleted via UI
2. ✅ All record types validate correctly
3. ✅ CNAME conflicts are prevented
4. ✅ Zone files can be imported with preview
5. ✅ Zone files can be exported in BIND format
6. ✅ Batch TTL updates work
7. ✅ UI updates in real-time via PubSub
8. ✅ Version conflicts are handled gracefully
9. ✅ All tests pass with >80% coverage
10. ✅ Documentation is updated

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Breaking existing zones | Add migration path for metadata |
| Performance regression | Benchmark before/after |
| Import parser edge cases | Comprehensive test fixtures |
| Concurrent edit conflicts | Clear UI messaging on conflicts |

---

## Dependencies

This feature depends on:
- Existing Auth zone implementation
- Existing RrLive pages
- Phoenix PubSub (already configured)
- DaisyUI components (already available)

No new external dependencies required.
