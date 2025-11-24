# Tasks: Console Settings Management

**Input**: Design documents from `/specs/001-console-settings/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/settings-api.md

**Tests**: LiveView integration tests and unit tests are included as per constitution requirements.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US5)
- Include exact file paths in descriptions

## Path Conventions

This is an Elixir umbrella project with the following structure:
- **Core app**: `apps/yellow_dog/` - Configuration management logic
- **Console app**: `apps/yellow_dog_console/` - Phoenix LiveView web console
- **Tests**: `apps/yellow_dog_console/test/` and `apps/yellow_dog/test/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Create feature branch `001-console-settings` from `develop` branch
- [x] T002 [P] Create directory `apps/yellow_dog_console/lib/yellow_dog/console/settings/` for Ecto schemas
- [x] T003 [P] Create directory `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/` for components
- [x] T004 [P] Create directory `apps/yellow_dog_console/test/yellow_dog/console/live/` for LiveView tests
- [x] T005 [P] Create directory `apps/yellow_dog_console/test/yellow_dog/console/settings/` for unit tests

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Configuration Management Foundation

- [ ] T006 Implement `YellowDog.Console.Settings.ConfigurationVersion` Agent in `apps/yellow_dog_console/lib/yellow_dog/console/settings/configuration_version.ex`
- [ ] T007 [P] Add `start_link/1` function to start Agent with ETS table for version tracking
- [ ] T008 [P] Add `get_version/1` function to retrieve version and file timestamp
- [ ] T009 [P] Add `compare_and_swap/3` function for atomic version check and increment
- [ ] T010 [P] Add `increment_version/0` function for external file modification handling

### Validation Foundation

- [ ] T011 Create `YellowDog.Console.Validators` module in `apps/yellow_dog_console/lib/yellow_dog/console/validators.ex`
- [ ] T012 [P] Implement `validate_ip/2` for IPv4/IPv6 address validation
- [ ] T013 [P] Implement `validate_port/1` for port range validation (1-65535)
- [ ] T014 [P] Implement `validate_pool_range/3` for IP range validation
- [ ] T015 [P] Implement `check_overlapping_pools/2` for pool overlap detection
- [ ] T016 Write unit tests for validators in `apps/yellow_dog_console/test/yellow_dog/console/validators_test.exs`

### TOML Configuration Management Foundation

- [ ] T017 Create `YellowDog.Console.ConfigManager` module in `apps/yellow_dog_console/lib/yellow_dog/console/config_manager.ex`
- [ ] T018 [P] Implement `load_config/1` for reading TOML configuration files
- [ ] T019 [P] Implement `save_config/3` with line-based partial update and atomic write
- [ ] T020 [P] Implement `create_backup/1` for timestamped backup creation
- [ ] T021 [P] Implement `list_backups/1` for backup file listing
- [ ] T022 [P] Implement `rotate_backups/2` to keep last 10 backups
- [ ] T023 [P] Implement `restore_backup/2` for configuration recovery
- [ ] T024 [P] Implement `create_default_config/1` for default configuration generation
- [ ] T025 [P] Implement `create_minimal_config/1` for minimal valid configuration
- [ ] T026 Write integration tests for ConfigManager in `apps/yellow_dog_console/test/yellow_dog/console/config_manager_test.exs`

### Data Model Foundation (Ecto Schemas)

- [ ] T027 Create `YellowDog.Console.Settings.ServiceConfiguration` schema in `apps/yellow_dog_console/lib/yellow_dog/console/settings/service_configuration.ex`
- [ ] T028 [P] Add embedded schema fields: enabled, listen, port, service_type, mode, domain, dns_servers, gateway
- [ ] T029 [P] Implement `changeset/2` with validation rules
- [ ] T030 [P] Add `validate_service_specific/1` for service-type-specific validation
- [ ] T031 Create `YellowDog.Console.Settings.AddressPool` schema in `apps/yellow_dog_console/lib/yellow_dog/console/settings/address_pool.ex`
- [ ] T032 [P] Add embedded schema fields: id, name, range_start, range_end, lease_time, preferred_lifetime, valid_lifetime, gateway, dns_servers, protocol
- [ ] T033 [P] Implement `changeset/2` with validation rules
- [ ] T034 [P] Add `validate_protocol_specific/1` for IPv4/IPv6 protocol validation
- [ ] T035 Write unit tests for schemas in `apps/yellow_dog_console/test/yellow_dog/console/settings/service_configuration_test.exs`

### Service Restart Foundation

- [ ] T036 Create `YellowDog.Console.ServiceManager` module in `apps/yellow_dog_console/lib/yellow_dog/console/service_manager.ex`
- [ ] T037 [P] Implement `apply_and_restart/2` for service configuration application and restart
- [ ] T038 [P] Add helper functions: `get_supervisor_pid/1`, `terminate_supervisor/1`, `wait_for_restart/3`, `verify_service_health/2`
- [ ] T039 [P] Add telemetry event emission for service restart operations
- [ ] T040 Extend `YellowDog.Config` with `update/2` function in `apps/yellow_dog/lib/yellow_dog/config.ex`
- [ ] T041 [P] Extend `YellowDog.Config` with `compare_and_swap/3` function for atomic configuration updates
- [ ] T042 Write tests for Config extensions in `apps/yellow_dog/test/yellow_dog/config_test.exs`

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - View and Edit DNS Configuration (Priority: P1) 🎯 MVP

**Goal**: Enable administrators to view, modify, save, and apply DNS service configuration (enabled/disabled, listen address, port) through the web console with pending/apply workflow.

**Independent Test**: Navigate to /settings, view DNS configuration, modify port from 53 to 5353, save (marked pending), apply changes (service restarts), verify config file updated and pending indicator clears.

### Main LiveView Implementation

- [ ] T043 [US1] Create `YellowDog.Console.SettingsLive` module in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex`
- [ ] T044 [US1] Implement `mount/3` to load configuration, version tracking, and initialize assigns
- [ ] T045 [US1] Implement `handle_event("switch_tab", ...)` for tab navigation
- [ ] T046 [US1] Implement `handle_event("validate_field", ...)` for real-time field validation
- [ ] T047 [US1] Implement `handle_event("save_configuration", ...)` for saving DNS config with optimistic locking
- [ ] T048 [US1] Implement `handle_event("apply_changes", ...)` for applying pending DNS configuration
- [ ] T049 [US1] Implement `handle_info/2` for async task completion (apply changes task)
- [ ] T050 [US1] Add helper functions: `has_pending_changes?/2`, `get_pending_config/2`, `handle_conflict/2`

### DNS Tab Component

- [ ] T051 [US1] Create DNS tab component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dns_component.ex`
- [ ] T052 [US1] Implement function component with form fields: enabled toggle, listen address input, port number input
- [ ] T053 [US1] Add DaisyUI form styling and error state display
- [ ] T054 [US1] Add "Save" button with validation state handling
- [ ] T055 [US1] Add "Apply Changes" button that appears when pending changes exist
- [ ] T056 [US1] Add pending indicator badge on tab

### Main Template

- [ ] T057 [US1] Create main settings template in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.html.heex`
- [ ] T058 [US1] Add tabbed interface with 4 tabs: DNS, mDNS, DHCPv4, DHCPv6
- [ ] T059 [US1] Add pending status badges on tabs
- [ ] T060 [US1] Add conflict resolution modal placeholder
- [ ] T061 [US1] Add recovery modal placeholder

### Routing

- [ ] T062 [US1] Add `/settings` route to `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`

### Tests for User Story 1

- [ ] T063 [P] [US1] Write LiveView mount test in `apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs`
- [ ] T064 [P] [US1] Write tab navigation test
- [ ] T065 [P] [US1] Write DNS configuration validation test
- [ ] T066 [P] [US1] Write DNS save configuration test
- [ ] T067 [P] [US1] Write DNS apply changes test with service restart
- [ ] T068 [P] [US1] Write optimistic locking conflict test
- [ ] T069 [P] [US1] Write persistence test (page refresh with pending changes)

**Checkpoint**: At this point, User Story 1 (DNS configuration management) should be fully functional and testable independently. Test by navigating to /settings, editing DNS config, saving, applying, and verifying.

---

## Phase 4: User Story 5 - Configuration Validation and Error Handling (Priority: P1)

**Goal**: Provide immediate validation feedback for invalid configuration values, handle concurrent modifications, and enable configuration recovery from missing/corrupted files.

**Independent Test**: Attempt to enter invalid IP address, port out of range, invalid IPv6 address in any tab. Verify validation errors displayed and save prevented. Test concurrent edit conflict and file recovery scenarios.

### Validation UI Integration

- [ ] T070 [US5] Update `SettingsLive.handle_event("validate_field", ...)` to use real-time changeset validation
- [ ] T071 [US5] Add error message display in DNS component form fields
- [ ] T072 [US5] Disable save button when validation errors exist

### Conflict Resolution Modal

- [ ] T073 [US5] Create conflict resolution modal component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/conflict_modal_component.ex`
- [ ] T074 [US5] Implement modal UI with conflict explanation and current file contents
- [ ] T075 [US5] Add "Reload and Discard Changes" action
- [ ] T076 [US5] Add "Cancel" action
- [ ] T077 [US5] Implement `handle_event("reload_configuration", ...)` in SettingsLive

### Configuration Recovery Modal

- [ ] T078 [US5] Create recovery modal component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/recovery_modal_component.ex`
- [ ] T079 [US5] Implement modal UI with 3 recovery options: Use Defaults, Restore from Backup, Create New
- [ ] T080 [US5] Add backup list display when "Restore from Backup" is selected
- [ ] T081 [US5] Implement `handle_event("recover_configuration", ...)` in SettingsLive
- [ ] T082 [US5] Add error detection logic in `mount/3` to trigger recovery modal

### Tests for User Story 5

- [ ] T083 [P] [US5] Write validation error test for invalid IP address
- [ ] T084 [P] [US5] Write validation error test for port out of range (99999)
- [ ] T085 [P] [US5] Write validation error test for malformed IP (256.1.1.1)
- [ ] T086 [P] [US5] Write concurrent administrator conflict test (version mismatch)
- [ ] T087 [P] [US5] Write external file modification test (timestamp mismatch)
- [ ] T088 [P] [US5] Write configuration recovery test (file missing)
- [ ] T089 [P] [US5] Write configuration recovery test (file corrupted)
- [ ] T090 [P] [US5] Write backup restoration test

**Checkpoint**: At this point, User Stories 1 AND 5 should both work. Validation prevents errors, conflicts are handled gracefully, and recovery works for missing/corrupted files.

---

## Phase 5: User Story 2 - View and Edit mDNS Configuration (Priority: P2)

**Goal**: Enable administrators to view, modify, save, and apply mDNS service configuration (enabled/disabled, listen address, port, mode: responder/hybrid) through the web console.

**Independent Test**: Navigate to /settings, click mDNS tab, toggle service enabled, change port, select mode, save, apply, verify changes persist.

### mDNS Tab Component

- [ ] T091 [US2] Create mDNS tab component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/mdns_component.ex`
- [ ] T092 [US2] Implement function component with form fields: enabled toggle, listen address input, port number input
- [ ] T093 [US2] Add mode selection field (responder/hybrid) using DaisyUI select
- [ ] T094 [US2] Add DaisyUI form styling and error state display
- [ ] T095 [US2] Add "Save" button with validation state handling
- [ ] T096 [US2] Add "Apply Changes" button for pending changes

### mDNS Configuration Logic

- [ ] T097 [US2] Update `SettingsLive.handle_event("save_configuration", ...)` to support mDNS service
- [ ] T098 [US2] Update `SettingsLive.handle_event("apply_changes", ...)` to support mDNS service restart
- [ ] T099 [US2] Add mDNS-specific validation in ServiceConfiguration changeset

### Tests for User Story 2

- [ ] T100 [P] [US2] Write mDNS tab rendering test
- [ ] T101 [P] [US2] Write mDNS toggle enabled/disabled test
- [ ] T102 [P] [US2] Write mDNS mode selection test
- [ ] T103 [P] [US2] Write mDNS save configuration test
- [ ] T104 [P] [US2] Write mDNS apply changes test
- [ ] T105 [P] [US2] Write mDNS configuration persistence test

**Checkpoint**: At this point, User Stories 1, 2, and 5 should all work independently. DNS and mDNS can both be configured via the web console.

---

## Phase 6: User Story 3 - View and Edit DHCPv4 Configuration (Priority: P2)

**Goal**: Enable administrators to view, modify DHCPv4 service configuration AND manage address pools (create, edit, delete pools) through the web console with full CRUD support.

**Independent Test**: Navigate to /settings, click DHCPv4 tab, create a new pool with range/lease time/gateway, edit pool settings, delete a pool, save, apply, verify all changes in config file.

### DHCPv4 Tab Component

- [ ] T106 [US3] Create DHCPv4 tab component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dhcpv4_component.ex`
- [ ] T107 [US3] Implement function component with service form fields: enabled toggle, listen address, port
- [ ] T108 [US3] Add pool list display with table showing pool name, range, lease time, gateway
- [ ] T109 [US3] Add "Add Pool" button to open pool form modal
- [ ] T110 [US3] Add pool action buttons: Edit, Delete for each pool
- [ ] T111 [US3] Add DaisyUI styling for pool table

### Pool Form Modal Component

- [ ] T112 [US3] Create pool form modal component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/pool_form_component.ex`
- [ ] T113 [US3] Implement LiveComponent with modal dialog
- [ ] T114 [US3] Add pool form fields: name, range_start, range_end, lease_time, gateway, dns_servers
- [ ] T115 [US3] Add real-time validation with changeset
- [ ] T116 [US3] Support both create mode and edit mode
- [ ] T117 [US3] Implement `handle_event("save", ...)` for pool creation/update

### Pool Management Events

- [ ] T118 [US3] Implement `handle_event("add_pool", ...)` in SettingsLive to open pool modal
- [ ] T119 [US3] Implement `handle_event("edit_pool", ...)` in SettingsLive to open pool modal with existing data
- [ ] T120 [US3] Implement `handle_event("delete_pool", ...)` in SettingsLive with confirmation
- [ ] T121 [US3] Implement `handle_event("validate_pool", ...)` for real-time pool validation
- [ ] T122 [US3] Implement `handle_event("save_pool", ...)` for adding/updating pool in configuration

### DHCPv4 Configuration Logic

- [ ] T123 [US3] Update `SettingsLive.handle_event("save_configuration", ...)` to support DHCPv4 with pools
- [ ] T124 [US3] Update `SettingsLive.handle_event("apply_changes", ...)` to support DHCPv4 service restart
- [ ] T125 [US3] Update TOML encoding in ConfigManager to handle pool arrays

### Tests for User Story 3

- [ ] T126 [P] [US3] Write DHCPv4 tab rendering test with pool list
- [ ] T127 [P] [US3] Write pool creation test
- [ ] T128 [P] [US3] Write pool edit test
- [ ] T129 [P] [US3] Write pool delete test with confirmation
- [ ] T130 [P] [US3] Write pool validation test (overlapping ranges)
- [ ] T131 [P] [US3] Write DHCPv4 save configuration with pools test
- [ ] T132 [P] [US3] Write DHCPv4 apply changes test
- [ ] T133 [P] [US3] Write pool TOML persistence test

**Checkpoint**: At this point, User Stories 1, 2, 3, and 5 should all work. DHCPv4 pool management is fully functional with CRUD operations.

---

## Phase 7: User Story 4 - View and Edit DHCPv6 Configuration (Priority: P3)

**Goal**: Enable administrators to view, modify DHCPv6 service configuration AND manage IPv6 address pools (create, edit, delete pools) through the web console.

**Independent Test**: Navigate to /settings, click DHCPv6 tab, create a new IPv6 pool with range/preferred lifetime/valid lifetime, edit pool, delete pool, save, apply, verify changes.

### DHCPv6 Tab Component

- [ ] T134 [US4] Create DHCPv6 tab component in `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dhcpv6_component.ex`
- [ ] T135 [US4] Implement function component with service form fields: enabled toggle, listen address (IPv6), port
- [ ] T136 [US4] Add IPv6 pool list display with table showing pool name, IPv6 range, preferred lifetime, valid lifetime
- [ ] T137 [US4] Add "Add Pool" button to open pool form modal
- [ ] T138 [US4] Add pool action buttons: Edit, Delete for each IPv6 pool

### DHCPv6 Pool Form

- [ ] T139 [US4] Extend pool form modal to support IPv6 protocol mode
- [ ] T140 [US4] Add IPv6-specific fields: preferred_lifetime, valid_lifetime
- [ ] T141 [US4] Add IPv6 address validation in pool form
- [ ] T142 [US4] Add preferred_lifetime <= valid_lifetime validation
- [ ] T143 [US4] Update pool form component to handle protocol selection (IPv4 vs IPv6)

### DHCPv6 Configuration Logic

- [ ] T144 [US4] Update `SettingsLive.handle_event("save_configuration", ...)` to support DHCPv6 with pools
- [ ] T145 [US4] Update `SettingsLive.handle_event("apply_changes", ...)` to support DHCPv6 service restart
- [ ] T146 [US4] Update pool management events to support IPv6 protocol

### Tests for User Story 4

- [ ] T147 [P] [US4] Write DHCPv6 tab rendering test with IPv6 pool list
- [ ] T148 [P] [US4] Write IPv6 pool creation test
- [ ] T149 [P] [US4] Write IPv6 pool edit test
- [ ] T150 [P] [US4] Write IPv6 pool delete test
- [ ] T151 [P] [US4] Write IPv6 address validation test
- [ ] T152 [P] [US4] Write lifetime validation test (preferred <= valid)
- [ ] T153 [P] [US4] Write DHCPv6 save configuration with pools test
- [ ] T154 [P] [US4] Write DHCPv6 apply changes test

**Checkpoint**: All user stories (1, 2, 3, 4, 5) should now be independently functional. All 4 services can be configured via the web console.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

### Telemetry Integration

- [ ] T155 [P] Add telemetry events for configuration load operations in ConfigManager
- [ ] T156 [P] Add telemetry events for configuration save operations in ConfigManager
- [ ] T157 [P] Add telemetry events for validation errors in SettingsLive
- [ ] T158 [P] Add telemetry events for apply changes operations in ServiceManager
- [ ] T159 [P] Add telemetry events for service restart success/failure

### Code Quality

- [ ] T160 Run `mix format` on all new files
- [ ] T161 Run `mix credo --strict` and fix all warnings
- [ ] T162 Run `mix dialyzer` and fix all type errors
- [ ] T163 Run `mix compile --warnings-as-errors` and fix all warnings
- [ ] T164 Review code for security vulnerabilities (XSS, injection attacks)

### Documentation

- [ ] T165 [P] Update CLAUDE.md with settings page patterns in `apps/yellow_dog_console/CLAUDE.md`
- [ ] T166 [P] Add inline documentation (@moduledoc, @doc) to all new modules
- [ ] T167 Run quickstart.md validation (test all manual scenarios)

### Performance Validation

- [ ] T168 Test page load time < 2 seconds
- [ ] T169 Test save operation time < 3 seconds (95th percentile)
- [ ] T170 Test real-time validation feedback < 100ms

### Final Integration Testing

- [ ] T171 Test complete workflow: DNS → mDNS → DHCPv4 → DHCPv6 configuration in sequence
- [ ] T172 Test concurrent administrator scenario (two browsers editing simultaneously)
- [ ] T173 Test external file modification scenario (edit config.toml while page loaded)
- [ ] T174 Test configuration recovery flow (delete config.toml, trigger recovery)
- [ ] T175 Test backup rotation (create 15 saves, verify only last 10 backups kept)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational completion - MVP target
- **User Story 5 (Phase 4)**: Depends on Foundational + US1 completion - Critical validation layer
- **User Story 2 (Phase 5)**: Depends on Foundational + US1 completion - Independent from US3/US4
- **User Story 3 (Phase 6)**: Depends on Foundational + US1 completion - Independent from US2/US4
- **User Story 4 (Phase 7)**: Depends on Foundational + US1 + US3 completion (reuses pool modal)
- **Polish (Phase 8)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 5 (P1)**: Depends on US1 (needs SettingsLive base implementation) - Critical for all stories
- **User Story 2 (P2)**: Depends on US1 + US5 - Independent from US3/US4 (can run in parallel)
- **User Story 3 (P2)**: Depends on US1 + US5 - Independent from US2 (can run in parallel with US2)
- **User Story 4 (P3)**: Depends on US1 + US5 + US3 (reuses pool modal component)

### Within Each User Story

- Setup tasks can run in parallel
- Foundational tasks marked [P] can run in parallel (within Phase 2)
- Tests for a user story marked [P] can run in parallel
- Components marked [P] can run in parallel
- User Story 2 and User Story 3 can be developed in parallel after US1+US5 complete

### Parallel Opportunities

#### Phase 2: Foundational

```bash
# Parallel group 1: Configuration Version Tracker functions
T007, T008, T009, T010

# Parallel group 2: Validators
T012, T013, T014, T015

# Parallel group 3: ConfigManager functions
T018, T019, T020, T021, T022, T023, T024, T025

# Parallel group 4: Ecto schema fields
T028, T029, T030, T032, T033, T034

# Parallel group 5: Service Manager helpers
T037, T038, T039
```

#### Phase 3: User Story 1 Tests

```bash
# All tests can run in parallel after implementation:
T063, T064, T065, T066, T067, T068, T069
```

#### Phase 4: User Story 5 Tests

```bash
# All tests can run in parallel after implementation:
T083, T084, T085, T086, T087, T088, T089, T090
```

#### Phase 5 & 6: User Stories 2 and 3

```bash
# After US1 + US5 complete, these can run in parallel:
# Developer A: User Story 2 (T091-T105)
# Developer B: User Story 3 (T106-T133)
```

#### Phase 8: Polish Tasks

```bash
# Parallel group: Telemetry
T155, T156, T157, T158, T159

# Parallel group: Documentation
T165, T166
```

---

## Parallel Example: Foundational Phase

```bash
# Launch all validator functions together:
Task: "Implement validate_ip/2 for IPv4/IPv6 address validation"
Task: "Implement validate_port/1 for port range validation (1-65535)"
Task: "Implement validate_pool_range/3 for IP range validation"
Task: "Implement check_overlapping_pools/2 for pool overlap detection"

# Launch all ConfigManager backup functions together:
Task: "Implement create_backup/1 for timestamped backup creation"
Task: "Implement list_backups/1 for backup file listing"
Task: "Implement rotate_backups/2 to keep last 10 backups"
Task: "Implement restore_backup/2 for configuration recovery"
```

---

## Parallel Example: User Story 1

```bash
# Launch all US1 tests together after implementation complete:
Task: "Write LiveView mount test"
Task: "Write tab navigation test"
Task: "Write DNS configuration validation test"
Task: "Write DNS save configuration test"
Task: "Write DNS apply changes test with service restart"
Task: "Write optimistic locking conflict test"
Task: "Write persistence test (page refresh with pending changes)"
```

---

## Implementation Strategy

### MVP First (User Story 1 + User Story 5)

1. Complete Phase 1: Setup (T001-T005)
2. Complete Phase 2: Foundational (T006-T042) - CRITICAL
3. Complete Phase 3: User Story 1 (T043-T069) - DNS configuration
4. Complete Phase 4: User Story 5 (T070-T090) - Validation & error handling
5. **STOP and VALIDATE**: Test DNS configuration with validation independently
6. Deploy/demo if ready (MVP achieved!)

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 + User Story 5 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo (mDNS added)
4. Add User Story 3 → Test independently → Deploy/Demo (DHCPv4 with pools added)
5. Add User Story 4 → Test independently → Deploy/Demo (DHCPv6 with pools added)
6. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together (T001-T042)
2. Once Foundational is done:
   - Developer A: User Story 1 (T043-T069)
   - Developer A then: User Story 5 (T070-T090)
3. After US1 + US5 complete:
   - Developer A: User Story 2 (T091-T105)
   - Developer B: User Story 3 (T106-T133) in parallel
4. After US2 + US3 complete:
   - Developer A or B: User Story 4 (T134-T154)
5. Stories complete and integrate independently

---

## Task Count Summary

- **Phase 1 (Setup)**: 5 tasks
- **Phase 2 (Foundational)**: 37 tasks (T006-T042)
- **Phase 3 (User Story 1)**: 27 tasks (T043-T069)
- **Phase 4 (User Story 5)**: 21 tasks (T070-T090)
- **Phase 5 (User Story 2)**: 15 tasks (T091-T105)
- **Phase 6 (User Story 3)**: 28 tasks (T106-T133)
- **Phase 7 (User Story 4)**: 21 tasks (T134-T154)
- **Phase 8 (Polish)**: 21 tasks (T155-T175)

**Total: 175 tasks**

### Parallel Opportunities Identified

- **Foundational Phase**: 20+ tasks can run in parallel across 5 groups
- **User Story Tests**: All tests within a story can run in parallel
- **User Stories 2 & 3**: Can be developed in parallel after US1+US5
- **Polish Phase**: Telemetry and documentation tasks can run in parallel

### MVP Scope

**Recommended MVP**: User Story 1 (DNS) + User Story 5 (Validation)
- **Task count**: 5 (setup) + 37 (foundational) + 27 (US1) + 21 (US5) = **90 tasks**
- **Delivers**: Basic settings page with DNS configuration, validation, error handling, conflict resolution, and recovery
- **Independent test**: Full DNS workflow with validation and edge case handling

---

## Notes

- [P] tasks = different files, no dependencies, can run in parallel
- [Story] label maps task to specific user story for traceability (US1, US2, US3, US4, US5)
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All tasks follow constitutional requirements: warnings-as-errors, format, credo, dialyzer, ExUnit tests
- TOML file preservation uses line-based partial update from research.md findings
- Optimistic locking uses hybrid version counter + timestamp approach from research.md
- Service restart uses OTP supervisor terminate-and-restart pattern from research.md
