# Tasks: E2E Service Tests

**Input**: Design documents from `/specs/001-e2e-service-tests/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: E2E tests ARE the feature - implementation tasks create the test infrastructure.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1=DNS, US2=mDNS, US3=DHCPv4, US4=DHCPv6, US5=Run All)
- Include exact file paths in descriptions

## Path Conventions

- **E2E Tests**: `e2e_test/` at umbrella root
- **Support Modules**: `e2e_test/support/`
- **GitHub Actions**: `.github/workflows/`
- **Mix Config**: `mix.exs` at umbrella root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create E2E test directory structure and shared helpers

- [ ] T001 Create e2e_test/ directory structure per plan.md
- [ ] T002 Create e2e_test/test_helper.exs with ExUnit configuration and compiler paths
- [ ] T003 [P] Create e2e_test/support/service_helper.ex with start/stop/wait functions
- [ ] T004 [P] Create e2e_test/support/dns_client.ex using ex_dns library for DNS queries
- [ ] T005 [P] Create e2e_test/support/dhcp_client.ex using ex_dhcp library for DHCP messages

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Mix configuration and CI workflow that ALL user stories depend on

**CRITICAL**: No E2E test file can work until this phase is complete

- [ ] T006 Add mix aliases to mix.exs: test.e2e, test.e2e.dns, test.e2e.mdns, test.e2e.dhcpv4, test.e2e.dhcpv6
- [ ] T007 Create .github/workflows/e2e.yml with matrix jobs for dns, mdns, dhcpv4, dhcpv6
- [ ] T008 Verify e2e_test/ compiles with `mix compile` (no warnings)

**Checkpoint**: Foundation ready - individual E2E test files can now be created

---

## Phase 3: User Story 1 - DNS Service E2E Testing (Priority: P1)

**Goal**: E2E tests that start DNS server, send queries, and verify responses

**Independent Test**: `mix test.e2e.dns` starts DNS server on auto-selected port and verifies A record queries

### Implementation for User Story 1

- [ ] T009 [US1] Create e2e_test/dns_e2e_test.exs with ExUnit.Case setup
- [ ] T010 [US1] Implement setup callback to start YellowDog.Dns.Server with port: 0 in e2e_test/dns_e2e_test.exs
- [ ] T011 [US1] Implement on_exit callback for service cleanup in e2e_test/dns_e2e_test.exs
- [ ] T012 [US1] Add test "DNS server starts and accepts queries" in e2e_test/dns_e2e_test.exs
- [ ] T013 [US1] Add test "A record query returns correct IP" in e2e_test/dns_e2e_test.exs
- [ ] T014 [US1] Add test "Query for non-existent domain returns NXDOMAIN" in e2e_test/dns_e2e_test.exs
- [ ] T015 [US1] Verify `mix test.e2e.dns` passes locally

**Checkpoint**: DNS E2E tests functional - `mix test.e2e.dns` works independently

---

## Phase 4: User Story 2 - mDNS Service E2E Testing (Priority: P2)

**Goal**: E2E tests that start mDNS server, register services, and verify discovery

**Independent Test**: `mix test.e2e.mdns` starts mDNS server with unicast on loopback and verifies PTR/SRV queries

### Implementation for User Story 2

- [ ] T016 [US2] Create e2e_test/mdns_e2e_test.exs with ExUnit.Case setup
- [ ] T017 [US2] Implement setup callback to start YellowDog.Mdns.Server with unicast loopback config in e2e_test/mdns_e2e_test.exs
- [ ] T018 [US2] Implement on_exit callback for service cleanup in e2e_test/mdns_e2e_test.exs
- [ ] T019 [US2] Add test "mDNS server starts and registers test service" in e2e_test/mdns_e2e_test.exs
- [ ] T020 [US2] Add test "PTR query for service type returns registered service" in e2e_test/mdns_e2e_test.exs
- [ ] T021 [US2] Add test "SRV query returns correct host and port" in e2e_test/mdns_e2e_test.exs
- [ ] T022 [US2] Verify `mix test.e2e.mdns` passes locally

**Checkpoint**: mDNS E2E tests functional - `mix test.e2e.mdns` works independently

---

## Phase 5: User Story 3 - DHCPv4 Service E2E Testing (Priority: P3)

**Goal**: E2E tests that start DHCPv4 server and complete DISCOVER/OFFER/REQUEST/ACK handshake

**Independent Test**: `mix test.e2e.dhcpv4` starts DHCPv4 server and verifies full lease handshake

### Implementation for User Story 3

- [ ] T023 [US3] Create e2e_test/dhcpv4_e2e_test.exs with ExUnit.Case setup
- [ ] T024 [US3] Implement setup callback to start YellowDog.Dhcpv4.Server with port: 0 in e2e_test/dhcpv4_e2e_test.exs
- [ ] T025 [US3] Implement on_exit callback for service cleanup in e2e_test/dhcpv4_e2e_test.exs
- [ ] T026 [US3] Add test "DHCPv4 server starts successfully" in e2e_test/dhcpv4_e2e_test.exs
- [ ] T027 [US3] Add test "DISCOVER message receives OFFER with valid IP" in e2e_test/dhcpv4_e2e_test.exs
- [ ] T028 [US3] Add test "REQUEST after OFFER receives ACK with lease" in e2e_test/dhcpv4_e2e_test.exs
- [ ] T029 [US3] Verify `mix test.e2e.dhcpv4` passes locally

**Checkpoint**: DHCPv4 E2E tests functional - `mix test.e2e.dhcpv4` works independently

---

## Phase 6: User Story 4 - DHCPv6 Service E2E Testing (Priority: P4)

**Goal**: E2E tests that start DHCPv6 server and complete SOLICIT/ADVERTISE/REQUEST/REPLY handshake

**Independent Test**: `mix test.e2e.dhcpv6` starts DHCPv6 server and verifies full lease handshake

### Implementation for User Story 4

- [ ] T030 [US4] Create e2e_test/dhcpv6_e2e_test.exs with ExUnit.Case setup
- [ ] T031 [US4] Implement setup callback to start YellowDog.Dhcpv6.Server with port: 0 in e2e_test/dhcpv6_e2e_test.exs
- [ ] T032 [US4] Implement on_exit callback for service cleanup in e2e_test/dhcpv6_e2e_test.exs
- [ ] T033 [US4] Add test "DHCPv6 server starts successfully" in e2e_test/dhcpv6_e2e_test.exs
- [ ] T034 [US4] Add test "SOLICIT message receives ADVERTISE with valid IPv6" in e2e_test/dhcpv6_e2e_test.exs
- [ ] T035 [US4] Add test "REQUEST after ADVERTISE receives REPLY with lease" in e2e_test/dhcpv6_e2e_test.exs
- [ ] T036 [US4] Verify `mix test.e2e.dhcpv6` passes locally

**Checkpoint**: DHCPv6 E2E tests functional - `mix test.e2e.dhcpv6` works independently

---

## Phase 7: User Story 5 - Run All E2E Tests (Priority: P5)

**Goal**: Combined test runner and CI integration verification

**Independent Test**: `mix test.e2e` runs all four service tests successfully

### Implementation for User Story 5

- [ ] T037 [US5] Verify `mix test.e2e` runs all E2E tests and reports results
- [ ] T038 [US5] Push branch and verify GitHub Actions e2e.yml workflow runs
- [ ] T039 [US5] Fix any CI-specific issues (e.g., multicast, IPv6 availability)
- [ ] T040 [US5] Verify all matrix jobs pass: dns, mdns, dhcpv4, dhcpv6

**Checkpoint**: All E2E tests pass locally and in CI

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and cleanup

- [ ] T041 [P] Update CLAUDE.md with E2E test commands and patterns
- [ ] T042 [P] Add inline documentation to e2e_test/support/ modules
- [ ] T043 Run quickstart.md validation - verify all commands work as documented
- [ ] T044 Code cleanup - ensure no unused variables or compiler warnings

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Phase 2 completion
  - Can proceed in parallel once Phase 2 is done
  - Or sequentially in priority order (DNS → mDNS → DHCPv4 → DHCPv6)
- **User Story 5 (Phase 7)**: Depends on all individual service tests (Phase 3-6)
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (DNS)**: Can start after Phase 2 - No dependencies on other stories
- **US2 (mDNS)**: Can start after Phase 2 - No dependencies on other stories
- **US3 (DHCPv4)**: Can start after Phase 2 - No dependencies on other stories
- **US4 (DHCPv6)**: Can start after Phase 2 - No dependencies on other stories
- **US5 (Run All)**: Depends on US1-US4 completion

### Within Each User Story

- Create test file first
- Implement setup callback
- Implement cleanup callback
- Add individual test cases
- Verify test passes locally

### Parallel Opportunities

- T003, T004, T005 (support modules) can run in parallel
- Once Phase 2 completes, US1-US4 can be implemented in parallel by different developers
- T041, T042 (documentation) can run in parallel

---

## Parallel Example: Phase 1 Setup

```bash
# Launch support module creation in parallel:
Task: "Create e2e_test/support/service_helper.ex"
Task: "Create e2e_test/support/dns_client.ex"
Task: "Create e2e_test/support/dhcp_client.ex"
```

## Parallel Example: User Stories (after Phase 2)

```bash
# Developer A: DNS E2E (US1)
Task: "Create e2e_test/dns_e2e_test.exs"
# ... complete all US1 tasks

# Developer B: mDNS E2E (US2) - IN PARALLEL
Task: "Create e2e_test/mdns_e2e_test.exs"
# ... complete all US2 tasks

# Developer C: DHCPv4 E2E (US3) - IN PARALLEL
Task: "Create e2e_test/dhcpv4_e2e_test.exs"
# ... complete all US3 tasks
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (mix aliases, CI workflow)
3. Complete Phase 3: DNS E2E (US1)
4. **STOP and VALIDATE**: `mix test.e2e.dns` works locally
5. Push to verify CI runs (even if other services fail)

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. Add DNS E2E (US1) → `mix test.e2e.dns` works → MVP!
3. Add mDNS E2E (US2) → `mix test.e2e.mdns` works
4. Add DHCPv4 E2E (US3) → `mix test.e2e.dhcpv4` works
5. Add DHCPv6 E2E (US4) → `mix test.e2e.dhcpv6` works
6. Verify Run All (US5) → `mix test.e2e` works, CI green
7. Polish → Documentation complete

### Single Developer Strategy

Execute in order: T001 → T044 sequentially, verifying each checkpoint before proceeding.

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story
- Each user story should be independently runnable via its mix alias
- Services must start with port: 0 for auto-selection
- mDNS uses unicast to loopback in CI (no multicast)
- Verify tests pass locally before pushing to CI
- Commit after each phase checkpoint
