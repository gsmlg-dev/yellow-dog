# Tasks: Complete Logger to Telemetry Migration

**Feature**: Complete Logger to Telemetry Migration
**Branch**: `001-complete-logger-telemetry-migration`
**Generated**: 2025-12-23
**Total Tasks**: 58

## Implementation Strategy

**MVP Scope**: User Story 1 (DNS Query Resolver) + User Story 2 (Root Zone Management) - These are P1 priority and cover 65 of 156 Logger calls.

**Incremental Delivery**: Each user story is independently testable. After completing each story phase, run `mix test` and `mix compile --warnings-as-errors` to verify.

---

## Phase 1: Setup

**Goal**: Prepare for migration by identifying current state and adding new logger handlers.

- [X] T001 Audit current Logger calls with `grep -r "Logger\." apps/*/lib --include="*.ex" | grep -v "_test.exs" | wc -l` to establish baseline (Result: 156 total, 104 to migrate)
- [X] T002 Add DNS query telemetry handlers in `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- [X] T003 Add DNS cache telemetry handlers in `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- [X] T004 Add root zone telemetry handlers in `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- [X] T005 Add application lifecycle telemetry handlers in `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- [X] T006 Add console telemetry handlers in `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`

---

## Phase 2: Foundational

**Goal**: No foundational tasks required. All migrations can proceed independently per user story.

*No blocking prerequisites - proceed directly to user story phases.*

---

## Phase 3: User Story 1 - DNS Query Resolver Telemetry (P1)

**Story Goal**: DNS query resolution events emit structured telemetry for monitoring and debugging.

**Independent Test**: After completing this phase, DNS queries emit telemetry events. Verify with `mix test apps/yellow_dog_dns` and check no Logger calls remain in query modules.

### Query Resolver Module (main entry point)

- [ ] T007 [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/resolver.ex` to telemetry events
- [ ] T008 [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/resolver.ex`

### Query Forwarder Module

- [ ] T009 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/forwarder.ex` to telemetry events
- [ ] T010 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/forwarder.ex`

### Query Recursive Module

- [ ] T011 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/recursive.ex` to telemetry events
- [ ] T012 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/recursive.ex`

### Query Iterator Module

- [ ] T013 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/iterator.ex` to telemetry events
- [ ] T014 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/iterator.ex`

### Query Referral Module

- [ ] T015 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/referral.ex` to telemetry events
- [ ] T016 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/referral.ex`

### Cache Manager Module

- [ ] T017 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/manager.ex` to telemetry events
- [ ] T018 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/manager.ex`

### Cache Cleaner Module

- [ ] T019 [P] [US1] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/cleaner.ex` to telemetry events
- [ ] T020 [P] [US1] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/cleaner.ex`

### Verification

- [ ] T021 [US1] Verify US1 completion: `grep -r "Logger\." apps/yellow_dog_dns/lib/yellow_dog/dns/query --include="*.ex"` returns 0 results
- [ ] T022 [US1] Run `mix test apps/yellow_dog_dns` to verify all tests pass

---

## Phase 4: User Story 2 - Root Zone Management Telemetry (P1)

**Story Goal**: Root zone fetch and update events emit telemetry for monitoring zone health.

**Independent Test**: After completing this phase, root zone operations emit telemetry events. Verify with `mix test apps/yellow_dog_dns` and check no Logger calls remain in root_zone modules.

### Root Zone Fetcher Module

- [ ] T023 [US2] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/fetcher.ex` to telemetry events
- [ ] T024 [US2] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/fetcher.ex`

### Root Zone Manager Module

- [ ] T025 [P] [US2] Migrate Logger calls in `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/manager.ex` to telemetry events
- [ ] T026 [P] [US2] Remove `require Logger` from `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/manager.ex`

### Verification

- [ ] T027 [US2] Verify US2 completion: `grep -r "Logger\." apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone --include="*.ex"` returns 0 results
- [ ] T028 [US2] Run `mix compile --warnings-as-errors` for yellow_dog_dns to verify no unused Logger warnings

---

## Phase 5: User Story 3 - Core Application Lifecycle Telemetry (P2)

**Story Goal**: Application startup, configuration, and service orchestration events emit telemetry.

**Independent Test**: After completing this phase, application lifecycle events emit telemetry. Verify with `mix test apps/yellow_dog`.

### Application Module

- [ ] T029 [US3] Migrate Logger calls in `apps/yellow_dog/lib/yellow_dog/application.ex` to telemetry events
- [ ] T030 [US3] Remove `require Logger` from `apps/yellow_dog/lib/yellow_dog/application.ex`

### Config Module

- [ ] T031 [P] [US3] Migrate Logger calls in `apps/yellow_dog/lib/yellow_dog/config.ex` to telemetry events
- [ ] T032 [P] [US3] Remove `require Logger` from `apps/yellow_dog/lib/yellow_dog/config.ex`

### Service Manager Module

- [ ] T033 [P] [US3] Migrate Logger calls in `apps/yellow_dog/lib/yellow_dog/service_manager.ex` to telemetry events
- [ ] T034 [P] [US3] Remove `require Logger` from `apps/yellow_dog/lib/yellow_dog/service_manager.ex`

### Verification

- [ ] T035 [US3] Verify US3 completion: `grep -r "Logger\." apps/yellow_dog/lib/yellow_dog --include="*.ex"` returns 0 results
- [ ] T036 [US3] Run `mix test apps/yellow_dog` to verify all tests pass

---

## Phase 6: User Story 4 - Web Console Telemetry (P3)

**Story Goal**: Web console operations emit telemetry for monitoring user interactions.

**Independent Test**: After completing this phase, console operations emit telemetry. Verify with `mix test apps/yellow_dog_console`.

### Dashboard Live Module

- [ ] T037 [US4] Migrate Logger calls in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex` to telemetry events
- [ ] T038 [US4] Remove `require Logger` from `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`

### Settings Live Module

- [ ] T039 [P] [US4] Migrate Logger calls in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex` to telemetry events
- [ ] T040 [P] [US4] Remove `require Logger` from `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex`

### Console Service Manager Module

- [ ] T041 [P] [US4] Migrate Logger calls in `apps/yellow_dog_console/lib/yellow_dog/console/service_manager.ex` to telemetry events
- [ ] T042 [P] [US4] Remove `require Logger` from `apps/yellow_dog_console/lib/yellow_dog/console/service_manager.ex`

### Verification

- [ ] T043 [US4] Verify US4 completion: `grep -r "Logger\." apps/yellow_dog_console/lib --include="*.ex"` returns 0 results
- [ ] T044 [US4] Run `mix test apps/yellow_dog_console` to verify all tests pass

---

## Phase 7: User Story 5 - Infrastructure Library Telemetry (P3)

**Story Goal**: Infrastructure library events (rate limiter, DNS errors) emit telemetry.

**Independent Test**: After completing this phase, infrastructure events emit telemetry. Verify with `mix test apps/abyss` and `mix test apps/ex_dns`.

### Abyss Rate Limiter Module

- [ ] T045 [US5] Migrate Logger calls in `apps/abyss/lib/abyss/rate_limiter.ex` to telemetry events
- [ ] T046 [US5] Remove `require Logger` from `apps/abyss/lib/abyss/rate_limiter.ex`

### Ex DNS Error Module

- [ ] T047 [P] [US5] Migrate Logger calls in `apps/ex_dns/lib/dns/error.ex` to telemetry events
- [ ] T048 [P] [US5] Remove `require Logger` from `apps/ex_dns/lib/dns/error.ex`

### Verification

- [ ] T049 [US5] Run `mix test apps/abyss` to verify all tests pass
- [ ] T050 [US5] Run `mix test apps/ex_dns` to verify all tests pass

---

## Phase 8: Polish & Cross-Cutting Concerns

**Goal**: Final verification and cleanup across all applications.

- [ ] T051 Run full test suite with `mix test` to verify all tests pass
- [ ] T052 Run `mix compile --warnings-as-errors` to verify no unused Logger warnings
- [ ] T053 Run `mix format --check-formatted` to verify code formatting
- [ ] T054 Verify final Logger count: `grep -r "Logger\." apps/*/lib --include="*.ex" | grep -v "abyss/logger.ex" | grep -v "logger_handlers.ex" | grep -v "telemetry/application.ex" | wc -l` should be 0
- [ ] T055 Verify require Logger removed: `grep -r "require Logger" apps/*/lib --include="*.ex" | grep -v "abyss/logger.ex" | grep -v "logger_handlers.ex" | grep -v "telemetry/application.ex" | wc -l` should be 0
- [ ] T056 Verify all telemetry events include timing measurements where applicable (spot-check 3+ events per story phase)
- [ ] T057 Verify all telemetry events include `source: __MODULE__` in metadata (spot-check 3+ events per story phase)
- [ ] T058 Update CLAUDE.md with migration completion note in Recent Changes section

---

## Dependencies

```text
Phase 1 (Setup) → Phase 3-7 (User Stories) → Phase 8 (Polish)

User Story Dependencies:
- US1 (DNS Query): Independent, no dependencies
- US2 (Root Zone): Independent, no dependencies
- US3 (Core App): Independent, no dependencies
- US4 (Console): Independent, no dependencies
- US5 (Infrastructure): Independent, no dependencies

All user stories can be executed in parallel after Phase 1 completes.
```

## Parallel Execution Examples

### Maximum Parallelism (after Phase 1)

```text
Parallel Group A (DNS Query modules - T009-T020):
  - T009+T010: forwarder.ex
  - T011+T012: recursive.ex
  - T013+T014: iterator.ex
  - T015+T016: referral.ex
  - T017+T018: cache/manager.ex
  - T019+T020: cache/cleaner.ex

Parallel Group B (Root Zone modules - T023-T026):
  - T023+T024: fetcher.ex
  - T025+T026: manager.ex

Parallel Group C (Core App modules - T029-T034):
  - T029+T030: application.ex
  - T031+T032: config.ex
  - T033+T034: service_manager.ex

Parallel Group D (Console modules - T037-T042):
  - T037+T038: dashboard_live.ex
  - T039+T040: settings_live.ex
  - T041+T042: service_manager.ex

Parallel Group E (Infrastructure modules - T045-T048):
  - T045+T046: rate_limiter.ex
  - T047+T048: error.ex
```

### Recommended Execution Order

1. Complete Phase 1 (T001-T006) sequentially
2. Execute US1 and US2 in parallel (both P1 priority)
3. Execute US3 (P2 priority)
4. Execute US4 and US5 in parallel (both P3 priority)
5. Complete Phase 8 (T051-T056) sequentially

---

## Summary

| Phase | User Story | Tasks | Files | Parallel |
|-------|------------|-------|-------|----------|
| 1 | Setup | 6 | 1 | No |
| 2 | Foundational | 0 | 0 | N/A |
| 3 | US1 - DNS Query | 16 | 7 | Yes |
| 4 | US2 - Root Zone | 6 | 2 | Yes |
| 5 | US3 - Core App | 8 | 3 | Yes |
| 6 | US4 - Console | 8 | 3 | Yes |
| 7 | US5 - Infrastructure | 6 | 2 | Yes |
| 8 | Polish | 8 | 0 | No |
| **Total** | | **58** | **18** | |

### Migration Pattern Reference

For each file migration task, follow the quickstart.md guide:

```elixir
# Before (Logger call)
Logger.info("Query completed in #{duration}ms")

# After (Telemetry event)
:telemetry.execute(
  [:yellow_dog, :dns, :query, :complete],
  %{duration_ms: duration, count: 1},
  %{source: __MODULE__, query_name: query.name, result: :success}
)
```

### Exclusions (DO NOT MIGRATE)

- `apps/abyss/lib/abyss/logger.ex` - Intentional logging API
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex` - Telemetry-to-Logger bridge
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/application.ex` - Bootstrap logging
