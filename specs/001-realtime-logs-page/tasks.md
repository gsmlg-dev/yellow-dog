# Tasks: Real-time Logs Page

**Input**: Design documents from `/specs/001-realtime-logs-page/`
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, quickstart.md ✅

**Tests**: Tests are NOT explicitly requested. This task list focuses on implementation only.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Umbrella apps**: `apps/yellow_dog_console/lib/`, `apps/yellow_dog_telemetry/lib/`
- **Assets**: `apps/yellow_dog_console/assets/`
- **Tests**: `apps/yellow_dog_console/test/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create foundational components that all user stories depend on

- [x] T001 Create LogBroadcaster GenServer in `apps/yellow_dog_console/lib/yellow_dog/console/log_broadcaster.ex` (moved to Console app for Phoenix.PubSub access)
- [x] T002 Add LogBroadcaster to YellowDog.Console.Application supervisor in `apps/yellow_dog_console/lib/yellow_dog/console/application.ex`
- [x] T003 [P] Add LogAutoScroll JavaScript hook in `apps/yellow_dog_console/assets/js/app.js`
- [x] T004 Add /logs route in `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`

---

## Phase 2: Foundational (Core LiveView Structure)

**Purpose**: Create the base LogsLive module structure that all user stories build upon

**⚠️ CRITICAL**: User story implementation builds on this foundation

- [x] T005 Create LogsLive module skeleton with mount/2, render/1 in `apps/yellow_dog_console/lib/yellow_dog/console/live/logs_live.ex`
- [x] T006 Implement PubSub subscription in mount/3 (subscribe to "logs:stream" when connected)
- [x] T007 Implement handle_info for {:log_event, level, measurements, metadata} message
- [x] T008 Implement build_log_entry/3 helper function to transform telemetry metadata to LogEntry struct
- [x] T009 Implement log buffer management (add_log_entry, max 1000 entries, FIFO eviction)
- [x] T010 Implement basic render/1 with page layout, log container with phx-hook="LogAutoScroll"

**Checkpoint**: Foundation ready - base log display working, user stories add filtering and controls

---

## Phase 3: User Story 1 - View Real-time System Logs (Priority: P1) 🎯 MVP

**Goal**: Display real-time log entries as they occur with timestamp, level, app source, and message

**Independent Test**: Open /logs page, trigger log events (e.g., `YellowDog.Telemetry.info("test")`), verify entries appear in real-time

### Implementation for User Story 1

- [x] T011 [US1] Implement log entry row component with timestamp, level badge, app badge, message in `apps/yellow_dog_console/lib/yellow_dog/console/live/logs_live.ex`
- [x] T012 [US1] Add level_color/1 helper returning DaisyUI text color classes (debug=gray, info=blue, warning=amber, error=red)
- [x] T013 [US1] Add level_badge/1 helper returning DaisyUI badge classes
- [x] T014 [US1] Add app_name/1 helper to convert app atoms to display names (e.g., :yellow_dog_dns → "DNS")
- [x] T015 [US1] Add app_badge_color/1 helper for app-specific badge colors
- [x] T016 [US1] Add format_timestamp/1 helper (HH:MM:SS.mmm format)
- [x] T017 [US1] Implement metadata expand/collapse toggle on log entry click (store expanded_log_id in assigns)
- [x] T018 [US1] Render metadata as key-value pairs when entry is expanded
- [x] T019 [US1] Add empty state message when no logs are displayed ("Waiting for log events...")
- [x] T020 [US1] Style log container with monospace font, scrollable area, dark mode support

**Checkpoint**: Real-time log viewing complete - logs appear immediately with proper formatting

---

## Phase 4: User Story 2 - Filter Logs by Module/Application (Priority: P2)

**Goal**: Allow filtering log display by YellowDog module (DNS, DHCPv4, DHCPv6, mDNS, Console, Core)

**Independent Test**: Select DNS filter only, generate logs from multiple modules, verify only DNS logs appear

### Implementation for User Story 2

- [x] T021 [US2] Add selected_apps (MapSet) to socket assigns with default empty set (show all)
- [x] T022 [US2] Add available_apps constant list with {atom, display_name} tuples
- [x] T023 [US2] Implement should_display_app?/2 filter check (empty set = show all, otherwise check membership)
- [x] T024 [US2] Update handle_info to apply app filter before adding to log buffer
- [x] T025 [US2] Render module filter checkboxes in filter toolbar area
- [x] T026 [US2] Implement handle_event("toggle_app", %{"app" => app}, socket) to toggle app in selected_apps
- [x] T027 [US2] Show filter badge count when apps are filtered (e.g., "Showing: 2 of 6")
- [x] T028 [US2] Add "All" / "None" quick select buttons for module filter

**Checkpoint**: Module filtering complete - can focus on specific service logs

---

## Phase 5: User Story 3 - Filter Logs by Severity Level (Priority: P3)

**Goal**: Allow filtering by minimum log level (debug shows all, error shows only errors)

**Independent Test**: Select "Warning" level, generate debug/info/warning/error logs, verify only warning and error appear

### Implementation for User Story 3

- [x] T029 [US3] Add min_level (atom, default :debug) to socket assigns
- [x] T030 [US3] Add available_levels constant [:debug, :info, :warning, :error]
- [x] T031 [US3] Add @level_priority map constant for level comparison
- [x] T032 [US3] Implement should_display_level?/2 using priority comparison
- [x] T033 [US3] Update handle_info to apply level filter before adding to buffer
- [x] T034 [US3] Render level filter as radio buttons or select dropdown
- [x] T035 [US3] Implement handle_event("set_level", %{"level" => level}, socket) to update min_level
- [x] T036 [US3] Show current level filter in UI (e.g., "Min Level: Warning")

**Checkpoint**: Level filtering complete - can focus on errors/warnings

---

## Phase 6: User Story 4 - Control Log Streaming (Priority: P3)

**Goal**: Pause/resume log streaming and clear display

**Independent Test**: Click pause, generate logs, verify buffered count shows, click resume, verify logs appear

### Implementation for User Story 4

- [x] T037 [US4] Add paused (boolean, default false) to socket assigns
- [x] T038 [US4] Add pending_logs (list) and pending_count (integer) to socket assigns
- [x] T039 [US4] Update handle_info to buffer logs when paused instead of displaying
- [x] T040 [US4] Implement flush_pending/1 to merge pending into logs when resumed
- [x] T041 [US4] Render pause/resume button with toggle state (icon or text change)
- [x] T042 [US4] Implement handle_event("toggle_pause", _, socket) to toggle paused state
- [x] T043 [US4] Show pending count badge when paused and logs are buffered (e.g., "+15 pending")
- [x] T044 [US4] Render clear button in toolbar
- [x] T045 [US4] Implement handle_event("clear", _, socket) to empty logs list

**Checkpoint**: Stream control complete - can pause to examine logs, clear to reset

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Refinements that enhance all user stories

- [x] T046 [P] Add connection status indicator (connected/reconnecting) using phx-connected/phx-disconnected
- [ ] T047 [P] Implement rate limiting (batch updates every 100ms using Process.send_after) - DEFERRED for future optimization
- [x] T048 [P] Add page_title "Logs" to assigns for browser tab
- [x] T049 Run `mix format` on all new files
- [x] T050 Run `mix credo --strict` and fix any issues
- [x] T051 Verify dark mode styling for log viewer
- [ ] T052 Test manually with live services running (DNS, DHCP, mDNS) - USER TESTING REQUIRED
- [x] T053 Verify sidebar /logs link is active when on logs page (link exists at line 359 in layouts.ex)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion (T001-T004)
- **User Story 1 (Phase 3)**: Depends on Foundational (T005-T010)
- **User Story 2 (Phase 4)**: Depends on Foundational, can run parallel to US1
- **User Story 3 (Phase 5)**: Depends on Foundational, can run parallel to US1/US2
- **User Story 4 (Phase 6)**: Depends on Foundational, can run parallel to US1/US2/US3
- **Polish (Phase 7)**: Depends on all user stories complete

### User Story Dependencies

| Story | Depends On | Can Parallel With |
|-------|------------|-------------------|
| US1 (P1) | Foundational | - |
| US2 (P2) | Foundational | US1, US3, US4 |
| US3 (P3) | Foundational | US1, US2, US4 |
| US4 (P3) | Foundational | US1, US2, US3 |

### Within Each User Story

- Tasks are ordered by dependency
- [P] marked tasks can run in parallel
- Complete all tasks in a story before marking story complete

### Parallel Opportunities

**Phase 1 Parallel (T001 || T003):**
```
T001: LogBroadcaster GenServer
T003: JavaScript hook (different file, no dependency)
```
Then T002 (depends on T001), T004 (independent)

**After Foundational Complete:**
```
All user story phases can start in parallel:
- US1: T011-T020 (core display)
- US2: T021-T028 (module filter)
- US3: T029-T036 (level filter)
- US4: T037-T045 (stream control)
```

**Phase 7 Parallel (T046 || T047 || T048):**
```
T046: Connection status
T047: Rate limiting
T048: Page title
```

---

## Parallel Example: User Story 2

```bash
# These US2 tasks can run in parallel (different code sections):
T021: Add selected_apps to assigns
T022: Add available_apps constant
T023: Implement should_display_app?/2
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T010)
3. Complete Phase 3: User Story 1 (T011-T020)
4. **STOP and VALIDATE**: Test real-time log viewing works
5. Can deploy/demo - provides immediate monitoring value

### Incremental Delivery

1. **MVP**: Setup + Foundational + US1 → Real-time log viewing ✓
2. **+US2**: Add module filtering → Focused troubleshooting ✓
3. **+US3**: Add level filtering → Error/warning focus ✓
4. **+US4**: Add stream controls → Pause/examine/clear ✓
5. **Polish**: Connection status, rate limiting, styling

### Suggested MVP Scope

**Minimum Viable Product = Phase 1 + Phase 2 + Phase 3 (User Story 1)**

This delivers:
- Real-time log streaming from all services
- Proper formatting with timestamps, levels, app badges
- Auto-scroll with scroll-up override
- Buffer management (1000 entries max)
- Metadata expand on click

Value: Administrators can monitor system activity in real-time.

---

## Notes

- Sidebar already has /logs link (verified in layouts.ex lines 358-376)
- LogBroadcaster should be started in Console.Application supervisor
- All log events come from existing [:yellow_dog, :log, *] telemetry events
- PubSub topic: "logs:stream"
- DaisyUI classes used throughout for consistency
- Dark mode supported via existing theme toggle

---

## Summary

| Phase | Tasks | Focus |
|-------|-------|-------|
| Setup | 4 | Infrastructure |
| Foundational | 6 | Core LiveView |
| US1 (P1) | 10 | Real-time display |
| US2 (P2) | 8 | Module filter |
| US3 (P3) | 8 | Level filter |
| US4 (P3) | 9 | Stream control |
| Polish | 8 | Refinements |
| **Total** | **53** | |
