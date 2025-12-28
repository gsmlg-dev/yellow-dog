# Implementation Tasks: Process Map

**Feature**: 001-process-map
**Branch**: `001-process-map`
**Generated**: 2024-12-28
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

## Overview

| Phase | Description | Task Count |
|-------|-------------|------------|
| Phase 1 | Setup & Infrastructure | 3 |
| Phase 2 | Foundational - ProcessInspector Service | 4 |
| Phase 3 | User Story 1 - View Process Tree (P1) | 6 |
| Phase 4 | User Story 2 - View Process Status on Click (P2) | 4 |
| Phase 5 | User Story 3 - Navigate Process Hierarchy (P3) | 3 |
| Phase 6 | Polish & Cross-Cutting Concerns | 3 |
| **Total** | | **23** |

---

## Phase 1: Setup & Infrastructure

**Goal**: Establish routing and navigation for the Process Map feature.

- [x] T001 Add `/process-map` route to `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- [x] T002 Add "Process Map" menu item under System section in `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex`
- [x] T003 Create empty LiveView module stub in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`

---

## Phase 2: Foundational - ProcessInspector Service

**Goal**: Create the core service for process tree introspection. This must complete before any user story implementation.

**Blocking**: All user stories depend on this phase.

- [x] T004 Create `apps/yellow_dog_console/lib/yellow_dog/console/services/` directory if it doesn't exist
- [x] T005 [P] Implement `get_trees/0` function that returns supervision trees for all YellowDog apps in `apps/yellow_dog_console/lib/yellow_dog/console/services/process_inspector.ex`
- [x] T006 [P] Implement `get_process_status/1` function that returns detailed process info in `apps/yellow_dog_console/lib/yellow_dog/console/services/process_inspector.ex`
- [x] T007 [P] Implement helper functions (`format_mfa/1`, `format_memory/1`, `get_app_label/1`) in `apps/yellow_dog_console/lib/yellow_dog/console/services/process_inspector.ex`

---

## Phase 3: User Story 1 - View Process Tree (P1)

**Story**: As a system administrator, I want to see a visual tree diagram of all running Erlang/OTP processes in the system.

**Independent Test**: Navigate to `/process-map` and verify tree diagram appears showing YellowDog application supervision trees.

**Acceptance Criteria**:
- Tree displays for all started YellowDog applications
- Each node shows process name/identifier
- Tree updates automatically every 5 seconds

### Tasks

- [x] T008 [US1] Implement `mount/3` callback with initial tree fetch and 5-second timer in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T009 [US1] Implement `handle_info(:refresh_tree, socket)` for automatic tree updates in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T010 [P] [US1] Create `tree_node/1` function component for rendering individual nodes in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T011 [P] [US1] Create `application_tree/1` function component for rendering app-level trees in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T012 [US1] Implement main `render/1` function with page layout, header, and tree container in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T013 [US1] Add tree visualization CSS styles (expand/collapse indicators, indentation) to `apps/yellow_dog_console/assets/css/app.css`

---

## Phase 4: User Story 2 - View Process Status on Click (P2)

**Story**: As a system administrator, I want to click on any process node to see its status details.

**Independent Test**: Click any process node and verify status panel appears with PID, memory, message queue length, current function.

**Acceptance Criteria**:
- Clicking node shows status panel
- Panel shows: PID, registered name, current function, message queue length, memory
- Panel dismissible by clicking outside or pressing Escape
- Clicking different node updates panel

### Tasks

- [x] T014 [US2] Implement `handle_event("select_node", params, socket)` to fetch and display process status in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T015 [US2] Implement `handle_event("close_panel", params, socket)` to dismiss status panel in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T016 [P] [US2] Create `status_panel/1` function component for displaying process details in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T017 [US2] Add status panel styling and positioning (slide-out panel on right side) to `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`

---

## Phase 5: User Story 3 - Navigate Process Hierarchy (P3)

**Story**: As a system administrator, I want to expand and collapse tree branches to focus on specific parts of the hierarchy.

**Independent Test**: Click expand/collapse indicator on supervisor node and verify children toggle visibility.

**Acceptance Criteria**:
- Supervisor nodes have expand/collapse indicator
- Clicking indicator toggles children visibility
- Expansion state preserved across auto-refresh

### Tasks

- [x] T018 [US3] Add `expanded_pids` MapSet to socket assigns and preserve across refreshes in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T019 [US3] Implement `handle_event("toggle_expand", params, socket)` to toggle node expansion in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T020 [US3] Update `tree_node/1` component to respect expansion state and show expand/collapse indicator in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`

---

## Phase 6: Polish & Cross-Cutting Concerns

**Goal**: Handle edge cases, improve UX, ensure code quality.

- [x] T021 Handle edge case: process terminates while status panel open (show "Process terminated" message) in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T022 Add empty state UI when no processes available in `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex`
- [x] T023 Verify compilation with `mix compile --warnings-as-errors` and fix any warnings

---

## Dependencies

```
Phase 1 (Setup)
    │
    ▼
Phase 2 (ProcessInspector) ──► BLOCKING
    │
    ├──────────────────────────────────┐
    ▼                                  ▼
Phase 3 (US1: Tree)              (independent)
    │
    ▼
Phase 4 (US2: Status) ─────────► Depends on US1
    │
    ▼
Phase 5 (US3: Navigation) ─────► Depends on US1
    │
    ▼
Phase 6 (Polish)
```

### User Story Independence

| Story | Can Start After | Independent Test |
|-------|-----------------|------------------|
| US1 (P1) | Phase 2 complete | Navigate to /process-map, see tree |
| US2 (P2) | US1 complete | Click node, see status panel |
| US3 (P3) | US1 complete | Click expand/collapse, see toggle |

---

## Parallel Execution Opportunities

### Within Phase 2 (after T004)
```
T005 ─┬─ T006 ─┬─ T007
      │        │
      └────────┴──► All can run in parallel
```

### Within Phase 3 (after T008-T009)
```
T010 ─┬─ T011
      │
      └──► Both components can be developed in parallel
```

### Across Phases (after Phase 3)
```
Phase 4 (US2) ─┬─ Phase 5 (US3)
               │
               └──► Can develop in parallel after US1 complete
```

---

## Implementation Strategy

### MVP Scope (Recommended First Delivery)
- **Phase 1**: Setup (T001-T003)
- **Phase 2**: ProcessInspector (T004-T007)
- **Phase 3**: User Story 1 (T008-T013)

This delivers a working Process Map page that displays the supervision tree with auto-refresh. Users can see all processes but cannot yet click for details or collapse branches.

### Incremental Delivery
1. **MVP**: Phases 1-3 (View Tree) - ~13 tasks
2. **Enhancement 1**: Phase 4 (Click for Status) - +4 tasks
3. **Enhancement 2**: Phase 5 (Expand/Collapse) - +3 tasks
4. **Final**: Phase 6 (Polish) - +3 tasks

---

## File Summary

| File | Tasks | Purpose |
|------|-------|---------|
| `router.ex` | T001 | Add route |
| `layouts.ex` | T002 | Add sidebar item |
| `process_map_live.ex` | T003, T008-T012, T014-T022 | Main LiveView (17 tasks) |
| `process_inspector.ex` | T004-T007 | Service module |
| `app.css` | T013 | Tree styles |

---

## Verification Checklist

After completing all tasks:

- [x] Page loads at `/process-map` within 2 seconds
- [x] Tree shows all started YellowDog applications
- [x] Each node displays process name/PID
- [x] Tree auto-refreshes every 5 seconds
- [x] Clicking node shows status panel with required fields
- [x] Status panel dismissible
- [x] Expand/collapse works on supervisor nodes
- [x] Expansion state preserved across refresh
- [x] Empty state shown when no processes
- [x] Process termination handled gracefully
- [x] `mix compile --warnings-as-errors` passes (pre-existing warnings excluded)
- [x] `mix format --check-formatted` passes
