# Tasks: DNS Service Implementation Fix and Dashboard Service Controls

**Input**: Design documents from `/specs/001-dns-service/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in specification. Tests omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Umbrella project**: `apps/<app_name>/lib/yellow_dog/<module>/`
- DNS app: `apps/yellow_dog_dns/lib/yellow_dog/dns/`
- Console app: `apps/yellow_dog_console/lib/yellow_dog/console/`

---

## Phase 1: Setup (No Changes Needed)

**Purpose**: Existing project infrastructure is already in place

This feature modifies existing files only. No new project setup required.

**Checkpoint**: Proceed directly to foundational changes.

---

## Phase 2: Foundational (DNS Architecture Fix)

**Purpose**: Fix DNS supervisor architecture to match working services (mDNS, DHCPv4). This MUST be complete before any dashboard controls can work.

**⚠️ CRITICAL**: DNS service will not start until this phase is complete.

- [ ] T001 Remove `:ignore` conditional from `start_link/1` in `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex`
- [ ] T002 Add View.Manager child spec to `build_children/1` in `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex`
- [ ] T003 Add ConfigWatcher child spec (transient restart) to `build_children/1` in `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex`
- [ ] T004 Ensure correct child ordering in supervisor: Zone.Manager → Cache.Manager → Cache.Cleaner → RootZone.Manager → View.Manager → ConfigWatcher → Server
- [ ] T005 Remove inline `ViewManager.start_link()` from `init/1` in `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`
- [ ] T006 Remove inline ConfigWatcher creation (`start_config_watcher_if_enabled/1` call) from handler in `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`
- [ ] T007 Update handler state to use named process `YellowDog.Dns.View.Manager` instead of PID in `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`
- [ ] T008 Update `get_views/1` calls to use named ViewManager process in `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`
- [ ] T009 Verify DNS service compiles with `mix compile --warnings-as-errors` in `apps/yellow_dog_dns/`

**Checkpoint**: DNS service can now start successfully via `YellowDog.Dns.Supervisor.start_link([])`

---

## Phase 3: User Story 1 - Start DNS Service from Dashboard (Priority: P1) 🎯 MVP

**Goal**: Enable starting the DNS service from the dashboard with visual feedback.

**Independent Test**: Click "Start" on DNS service card → Status changes to "Running" within 5 seconds → DNS responds to queries.

### Implementation for User Story 1

- [ ] T010 [US1] Add `handle_event("start_service", %{"service" => service_str}, socket)` function in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T011 [US1] Implement service start logic: parse atom, call `YellowDog.start_service/1`, handle success/error in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T012 [US1] Add flash message for start success: `put_flash(:info, "Service started successfully")` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T013 [US1] Add flash message for start error: `put_flash(:error, "Failed to start: #{reason}")` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T014 [US1] Add Start button in `:actions` slot with `phx-click="start_service"` and `phx-value-service={service.key}` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T015 [US1] Style Start button with DaisyUI: `btn btn-sm btn-success gap-2` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T016 [US1] Add conditional rendering: show Start button only when `!service.running` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T017 [US1] Refresh service status after start by calling `assign(:services, get_service_status())` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`

**Checkpoint**: DNS service can be started from dashboard with visual feedback. MVP complete.

---

## Phase 4: User Story 2 - Stop DNS Service from Dashboard (Priority: P2)

**Goal**: Enable stopping the DNS service from the dashboard with graceful shutdown.

**Independent Test**: With DNS running, click "Stop" → Status changes to "Stopped" within 5 seconds → DNS no longer responds to queries.

### Implementation for User Story 2

- [ ] T018 [US2] Add `handle_event("stop_service", %{"service" => service_str}, socket)` function in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T019 [US2] Implement service stop logic: parse atom, call `YellowDog.stop_service/1`, handle success/error in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T020 [US2] Add flash message for stop success: `put_flash(:info, "Service stopped successfully")` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T021 [US2] Add flash message for stop error: `put_flash(:error, "Failed to stop: #{reason}")` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- [ ] T022 [US2] Add Stop button in `:actions` slot with `phx-click="stop_service"` and `phx-value-service={service.key}` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T023 [US2] Style Stop button with DaisyUI: `btn btn-sm btn-error gap-2` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T024 [US2] Add conditional rendering: show Stop button only when `service.running` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T025 [US2] Refresh service status after stop by calling `assign(:services, get_service_status())` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`

**Checkpoint**: DNS service can be started AND stopped from dashboard.

---

## Phase 5: User Story 3 - View DNS Service Status on Dashboard (Priority: P2)

**Goal**: Display accurate DNS service status (Running, Stopped, Error) with appropriate visual styling.

**Independent Test**: Dashboard accurately reflects DNS service state with correct colors and indicators.

### Implementation for User Story 3

- [ ] T026 [P] [US3] Verify `<.status_indicator>` component shows correct status based on `service.running` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T027 [P] [US3] Ensure status badge shows "Running" (green) when `service.running == true` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T028 [P] [US3] Ensure status badge shows "Stopped" (gray/neutral) when `service.running == false` in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T029 [US3] Add error status display when `service.error != nil` with error badge styling in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T030 [US3] Display error message in service card when `service.error` is present in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T031 [US3] Verify 5-second periodic refresh updates status correctly in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`

**Checkpoint**: Dashboard provides real-time accurate status for DNS service.

---

## Phase 6: User Story 4 - Consistent Service Controls Across All Services (Priority: P3)

**Goal**: All four services (DNS, mDNS, DHCPv4, DHCPv6) have identical control patterns.

**Independent Test**: All service cards show same Start/Stop buttons, same status indicators, same visual styling.

### Implementation for User Story 4

- [ ] T032 [P] [US4] Verify mDNS service card has Start/Stop buttons matching DNS pattern in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T033 [P] [US4] Verify DHCPv4 service card has Start/Stop buttons matching DNS pattern in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T034 [P] [US4] Verify DHCPv6 service card has Start/Stop buttons matching DNS pattern in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T035 [US4] Extract service card with controls to reusable component/pattern if needed in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- [ ] T036 [US4] Verify all services respond to same event handlers (`start_service`, `stop_service`) in `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`

**Checkpoint**: All four services have consistent UI controls.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and cleanup

- [ ] T037 Run `mix compile --warnings-as-errors` at umbrella root to verify no warnings
- [ ] T038 Run `mix format` at umbrella root to ensure code is formatted
- [ ] T039 Run `mix credo --strict` at umbrella root to check code quality
- [ ] T040 Verify DNS service starts via IEx: `iex -S mix` → `YellowDog.start_service(:dns)`
- [ ] T041 Verify DNS responds to queries: `dig @127.0.0.1 -p 53 example.com A`
- [ ] T042 Verify dashboard Start/Stop buttons work for all services via browser at `http://localhost:4270/dashboard`
- [ ] T043 [P] Verify periodic refresh (5 seconds) updates status after external changes

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: N/A - no setup required
- **Foundational (Phase 2)**: Must complete FIRST - blocks all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational - can start immediately after Phase 2
- **User Story 2 (Phase 4)**: Depends on Foundational - can run in parallel with US1
- **User Story 3 (Phase 5)**: Depends on Foundational - can run in parallel with US1/US2
- **User Story 4 (Phase 6)**: Depends on US1, US2, US3 (needs all buttons implemented first)
- **Polish (Phase 7)**: Depends on all user stories complete

### User Story Dependencies

- **User Story 1 (P1)**: Independent after Foundational - START button only
- **User Story 2 (P2)**: Independent after Foundational - STOP button only
- **User Story 3 (P2)**: Independent after Foundational - Status display only
- **User Story 4 (P3)**: Depends on US1+US2+US3 - consistency verification

### Task Dependencies Within Phase 2 (Foundational)

```
T001 (remove :ignore) ─────────────────────────────────────────────┐
T002 (add View.Manager) ──────────────────────────────────────────┤
T003 (add ConfigWatcher) ─────────────────────────────────────────┼─→ T004 (ordering)
T005 (remove ViewManager.start_link) ────────────────────────────┤
T006 (remove ConfigWatcher inline) ──────────────────────────────┤
T007 (update handler state) ─────────────────────────────────────┼─→ T008 (update calls)
                                                                  │
                                                                  └─→ T009 (verify compile)
```

### Parallel Opportunities

**Phase 2 (Foundational)**:
- T001, T002, T003 can run in parallel (supervisor.ex - different sections)
- T005, T006, T007 can run in parallel (handler/udp.ex - different sections)

**Phase 3-5 (User Stories 1, 2, 3)**:
- US1, US2, US3 can run in parallel after Foundational completes
- Each story modifies different aspects of the same files, so coordinate if parallel

**Phase 6 (User Story 4)**:
- T032, T033, T034 can run in parallel (verification tasks)

---

## Parallel Example: Foundational Phase

```bash
# Launch supervisor.ex changes together:
Task: T001 "Remove :ignore conditional from start_link/1"
Task: T002 "Add View.Manager child spec to build_children/1"
Task: T003 "Add ConfigWatcher child spec to build_children/1"

# Then launch handler/udp.ex changes together:
Task: T005 "Remove inline ViewManager.start_link() from init/1"
Task: T006 "Remove inline ConfigWatcher creation from handler"
Task: T007 "Update handler state to use named process"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (T001-T009)
2. Complete Phase 3: User Story 1 (T010-T017)
3. **STOP and VALIDATE**: Test DNS service starts from dashboard
4. Deploy/demo if ready - administrators can START DNS service

### Incremental Delivery

1. Phase 2: Foundational → DNS service can start programmatically
2. + User Story 1 → DNS can START from dashboard (MVP!)
3. + User Story 2 → DNS can STOP from dashboard
4. + User Story 3 → Clear status indication
5. + User Story 4 → All services consistent
6. Phase 7: Polish → Production ready

### Single Developer Strategy

Execute in order: Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6 → Phase 7

---

## Notes

- [P] tasks = different files or different sections, no dependencies
- [Story] label maps task to specific user story for traceability
- All tasks modify existing files - no new file creation required
- Commit after each task or logical group (e.g., after completing each phase)
- Stop at any checkpoint to validate story independently
- Existing API (`YellowDog.start_service/1`, `YellowDog.stop_service/1`) already works - dashboard just needs UI
