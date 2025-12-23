# Implementation Tasks: Telemetry-Based Logging System

**Feature Branch**: `001-telemetry-logging`
**Date**: 2025-12-22
**Plan**: [plan.md](./plan.md)
**Spec**: [spec.md](./spec.md)

---

## Summary

| Metric | Count |
|--------|-------|
| Total Tasks | 47 |
| Phase 1 (Setup) | 2 |
| Phase 2 (Foundational) | 6 |
| Phase 3 (US1 - Handler Attachment) | 8 |
| Phase 4 (US2 - Protocol Events) | 16 |
| Phase 5 (US3 - Migration) | 10 |
| Phase 6 (US4 - Log Level Config) | 3 |
| Phase 7 (Polish) | 2 |
| Parallelizable Tasks | 24 |

---

## MVP Scope

**Recommended MVP**: User Story 1 + User Story 2 (Phases 1-4)
- Provides complete telemetry infrastructure
- Enables protocol event emission
- Log output produced via attached handlers
- ~32 tasks for functional MVP

---

## Phase 1: Setup

> Project initialization tasks. No user story association.

- [x] T001 Verify `yellow_dog_telemetry` dependency is configured in all protocol app mix.exs files (apps/yellow_dog_dns/mix.exs, apps/yellow_dog_dhcpv4/mix.exs, apps/yellow_dog_dhcpv6/mix.exs, apps/yellow_dog_mdns/mix.exs)
- [x] T002 Create feature branch `001-telemetry-logging` from main if not already created

---

## Phase 2: Foundational

> Blocking prerequisites that must complete before user stories. No user story association.

- [x] T003 Create `YellowDog.Telemetry.LoggerHandlers` module scaffold in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex with @moduledoc and require Logger
- [x] T004 Add `@handler_ids` module attribute in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex listing all handler IDs for tracking
- [x] T005 [P] Add `format_ip/1` helper function in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to format IP tuples as strings
- [x] T006 [P] Add `format_mac/1` helper function in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to format MAC addresses
- [x] T007 [P] Add `format_duration/1` helper function in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to format durations
- [x] T008 Create test file apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs with ExUnit.Case setup

---

## Phase 3: User Story 1 - Centralized Log Handler Attachment (P1)

> **Goal**: All log output controlled through telemetry handler attachment
>
> **Independent Test**: Start application, verify telemetry events produce log output through attached handlers
>
> **Acceptance**:
> - `attach_logger_handlers/0` attaches all handlers
> - `detach_logger_handlers/0` removes all handlers
> - Silent operation when handlers not attached

### Core Handler Functions

- [x] T009 [US1] Implement `attach_logger_handlers/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry.ex that calls LoggerHandlers.attach_all/0
- [x] T010 [US1] Implement `detach_logger_handlers/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry.ex that calls LoggerHandlers.detach_all/0
- [x] T011 [US1] Implement `attach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex that attaches DNS, DHCPv4, DHCPv6, mDNS handlers using :telemetry.attach_many/4
- [x] T012 [US1] Implement `detach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex that detaches all handlers by ID

### Application Startup Integration

- [x] T013 [US1] Add call to `YellowDog.Telemetry.attach_logger_handlers/0` in apps/yellow_dog/lib/yellow_dog/application.ex before starting services in start/2

### Tests

- [x] T014 [P] [US1] Add test for attach_logger_handlers/0 in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs verifying handlers are attached
- [x] T015 [P] [US1] Add test for detach_logger_handlers/0 in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs verifying handlers are detached
- [x] T016 [P] [US1] Add test verifying silent operation when handlers not attached in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs

---

## Phase 4: User Story 2 - Protocol Service Telemetry Events (P1)

> **Goal**: All protocol services emit telemetry events instead of direct Logger calls
>
> **Independent Test**: Attach test handler to telemetry events, verify events fire during protocol operations
>
> **Acceptance**:
> - DNS emits query received, completed, error events
> - DHCPv4 emits lease requested, granted events
> - DHCPv6 emits lease requested, granted events
> - mDNS emits service registered event

### DNS Handler Implementation

- [x] T017 [P] [US2] Implement `handle_dns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex for query received/completed/error events with try/catch wrapper
- [x] T018 [P] [US2] Add DNS cache hit/miss and zone loaded formatting to `handle_dns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex
- [x] T019 [P] [US2] Add DNS server started/stopped formatting to `handle_dns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex

### DHCPv4 Handler Implementation

- [x] T020 [P] [US2] Implement `handle_dhcpv4_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex for lease requested/granted/released/expired events with try/catch wrapper
- [x] T021 [P] [US2] Add DHCPv4 server started/stopped formatting to `handle_dhcpv4_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex

### DHCPv6 Handler Implementation

- [x] T022 [P] [US2] Implement `handle_dhcpv6_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex for lease requested/granted/released/expired events with try/catch wrapper
- [x] T023 [P] [US2] Add DHCPv6 server started/stopped formatting to `handle_dhcpv6_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex

### mDNS Handler Implementation

- [x] T024 [P] [US2] Implement `handle_mdns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex for service registered/unregistered events with try/catch wrapper
- [x] T025 [P] [US2] Add mDNS query received and response sent formatting to `handle_mdns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex
- [x] T026 [P] [US2] Add mDNS server started/stopped formatting to `handle_mdns_event/4` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex

### Handler Registration

- [x] T027 [US2] Update `attach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to register DNS events with handle_dns_event/4
- [x] T028 [US2] Update `attach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to register DHCPv4 events with handle_dhcpv4_event/4
- [x] T029 [US2] Update `attach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to register DHCPv6 events with handle_dhcpv6_event/4
- [x] T030 [US2] Update `attach_all/0` in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to register mDNS events with handle_mdns_event/4

### Tests

- [x] T031 [P] [US2] Add test for DNS event formatting in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs
- [x] T032 [P] [US2] Add test for DHCPv4 event formatting in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs

---

## Phase 5: User Story 3 - Migrate Existing Logger Calls (P2)

> **Goal**: All existing direct Logger calls replaced with telemetry events
>
> **Independent Test**: Search codebase for `Logger.` calls, verify zero in protocol apps (excluding telemetry handlers)
>
> **Acceptance**:
> - Zero direct Logger calls in yellow_dog_dns, yellow_dog_dhcpv4, yellow_dog_dhcpv6, yellow_dog_mdns
> - All previous log messages still produced via telemetry handlers
> - Log parity maintained

### DNS Migration

- [x] T033 [US3] Migrate Logger calls in apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex to :telemetry.execute/3 with appropriate event names
  - Already using YellowDog.Telemetry API (Telemetry.info/2, Telemetry.debug/2, etc.) instead of direct Logger calls
- [ ] T034 [P] [US3] Migrate Logger calls in apps/yellow_dog_dns/lib/yellow_dog/dns/zone/*.ex files to :telemetry.execute/3 or YellowDog.Telemetry.info/2
- [ ] T035 [P] [US3] Migrate Logger calls in apps/yellow_dog_dns/lib/yellow_dog/dns/query/*.ex files to :telemetry.execute/3 or YellowDog.Telemetry.info/2

### DHCPv4 Migration

- [x] T036 [US3] Migrate Logger calls in apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/handler.ex to :telemetry.execute/3 with appropriate event names
- [ ] T037 [P] [US3] Migrate Logger calls in apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/lease_manager.ex to :telemetry.execute/3
- [ ] T038 [P] [US3] Migrate Logger calls in remaining apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/*.ex files to YellowDog.Telemetry API

### DHCPv6 Migration

- [x] T039 [US3] Migrate Logger calls in apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/handler.ex to :telemetry.execute/3 with appropriate event names
- [ ] T040 [P] [US3] Migrate Logger calls in remaining apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/*.ex files to :telemetry.execute/3 or YellowDog.Telemetry API

### mDNS Migration

- [x] T041 [US3] Migrate Logger calls in apps/yellow_dog_mdns/lib/yellow_dog/mdns/handler.ex to :telemetry.execute/3 with appropriate event names
- [ ] T042 [P] [US3] Migrate Logger calls in remaining apps/yellow_dog_mdns/lib/yellow_dog/mdns/*.ex files to :telemetry.execute/3 or YellowDog.Telemetry API

---

## Phase 6: User Story 4 - Log Level Configuration (P3)

> **Goal**: Configure log verbosity per service through telemetry handler configuration
>
> **Independent Test**: Modify handler configuration, verify only specified log levels appear
>
> **Acceptance**:
> - Per-service log level configuration works
> - Default is info-level and above

- [x] T043 [US4] Add per-service log level configuration to handler attachment in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex supporting :debug, :info, :warning, :error levels
  - Handlers attach with `%{level: :info}` config and pass level to Logger.log/2
- [x] T044 [US4] Update handler functions in apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex to respect config.level parameter
  - All handlers use `Logger.log(config.level, fn -> ... end)` pattern
- [x] T045 [P] [US4] Add test for per-service log level filtering in apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs
  - Test added in describe "per-service log level filtering" block

---

## Phase 7: Polish & Cross-Cutting Concerns

> Final cleanup and verification tasks. No user story association.

- [ ] T046 Verify all protocol apps compile with `--warnings-as-errors` after migration
- [ ] T047 Run grep search to confirm zero direct Logger calls remain in protocol apps (excluding telemetry handlers)

---

## Dependencies

```
Phase 1 (Setup)
    │
    ▼
Phase 2 (Foundational)
    │
    ▼
Phase 3 (US1: Handler Attachment) ─────────────────┐
    │                                               │
    ▼                                               │
Phase 4 (US2: Protocol Events) ◄───────────────────┤
    │                                               │
    ▼                                               │
Phase 5 (US3: Migration) ◄─────────────────────────┘
    │
    ▼
Phase 6 (US4: Log Level Config) [Optional Enhancement]
    │
    ▼
Phase 7 (Polish)
```

### User Story Dependencies

| Story | Depends On | Notes |
|-------|------------|-------|
| US1 | Setup, Foundational | Core infrastructure |
| US2 | US1 | Needs handlers attached to produce output |
| US3 | US1, US2 | Needs infrastructure and event handlers |
| US4 | US1, US2 | Enhancement on top of working system |

---

## Parallel Execution Opportunities

### Phase 2 Parallel Tasks
```
T005 ─┬─ format_ip helper
T006 ─┼─ format_mac helper     } All run in parallel
T007 ─┴─ format_duration helper
```

### Phase 3 Parallel Tasks
```
T014 ─┬─ test attach handlers
T015 ─┼─ test detach handlers    } All run in parallel
T016 ─┴─ test silent operation
```

### Phase 4 Parallel Tasks (Handler Implementation)
```
T017 ─┬─ DNS handler
T020 ─┼─ DHCPv4 handler      } All run in parallel (different files/services)
T022 ─┼─ DHCPv6 handler
T024 ─┴─ mDNS handler
```

### Phase 5 Parallel Tasks (Migration)
```
T034 ─┬─ DNS zone migration
T035 ─┼─ DNS query migration     } Run in parallel within DNS
```

```
T037 ─┬─ DHCPv4 lease_manager
T038 ─┴─ DHCPv4 other files      } Run in parallel within DHCPv4
```

---

## Implementation Strategy

### MVP Delivery (Phases 1-4)
1. Complete Setup and Foundational phases
2. Implement US1 (Handler Attachment) - enables logging infrastructure
3. Implement US2 (Protocol Events) - enables event emission
4. **Result**: Working telemetry logging system with handlers attached

### Full Feature (Phases 5-7)
5. Implement US3 (Migration) - removes all direct Logger calls
6. Implement US4 (Log Level Config) - adds per-service configuration
7. Polish - verify and clean up

### Incremental Verification
- After Phase 3: Test handler attachment/detachment
- After Phase 4: Test event emission produces log output
- After Phase 5: Grep search for remaining Logger calls
- After Phase 7: Full integration test

---

## Files Created/Modified

### New Files
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- `apps/yellow_dog_telemetry/test/yellow_dog/telemetry/logger_handlers_test.exs`

### Modified Files
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry.ex` (add attach/detach functions)
- `apps/yellow_dog/lib/yellow_dog/application.ex` (add startup call)
- `apps/yellow_dog_dns/lib/yellow_dog/dns/**/*.ex` (14 files - migration)
- `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/**/*.ex` (7 files - migration)
- `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/**/*.ex` (6 files - migration)
- `apps/yellow_dog_mdns/lib/yellow_dog/mdns/**/*.ex` (10 files - migration)
