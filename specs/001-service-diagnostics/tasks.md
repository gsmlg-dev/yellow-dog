# Tasks: Service Diagnostics Page

**Input**: Design documents from `/specs/001-service-diagnostics/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

All paths are relative to `apps/yellow_dog_console/`:
- **LiveView**: `lib/yellow_dog/console/live/diagnostics_live/`
- **Clients**: `lib/yellow_dog/console/diagnostics/`
- **Tests**: `test/yellow_dog/console/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Add `/diagnostics` route to router in `lib/yellow_dog/console/router.ex`
- [x] T002 [P] Create QueryResult struct in `lib/yellow_dog/console/diagnostics/query_result.ex`
- [x] T003 [P] Create HexFormatter module in `lib/yellow_dog/console/diagnostics/hex_formatter.ex`
- [x] T004 [P] Add CopyToClipboard JavaScript hook in `assets/js/app.js`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T005 Create main DiagnosticsLive LiveView with tab navigation in `lib/yellow_dog/console/live/diagnostics_live/diagnostics_live.ex`
- [x] T006 [P] Create ResultDisplay component (struct/raw toggle) in `lib/yellow_dog/console/live/diagnostics_live/components/result_display.ex`
- [x] T007 [P] Create HexDump component in `lib/yellow_dog/console/live/diagnostics_live/components/hex_dump.ex`
- [x] T008 [P] Create QueryHistory collapsible component in `lib/yellow_dog/console/live/diagnostics_live/components/query_history.ex`
- [x] T009 Implement tab state management with assigns (active_tab, display_mode, per-tab state) in `diagnostics_live.ex`
- [x] T010 Implement display mode toggle handler (struct/raw) in `diagnostics_live.ex`

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - DNS Query Testing (Priority: P1) 🎯 MVP

**Goal**: Send DNS queries to test DNS server configuration and verify name resolution

**Independent Test**: Enter a domain name and query type, click send, view DNS response with latency. Toggle between struct and raw views. Query history shows up to 10 entries.

### Implementation for User Story 1

- [x] T011 [P] [US1] Create DnsClient module with query/1 function in `lib/yellow_dog/console/diagnostics/dns_client.ex`
- [x] T012 [US1] Implement DNS message building using DNS.Message and DNS.to_iodata/1 in `dns_client.ex`
- [x] T013 [US1] Implement UDP query execution with :gen_udp in `dns_client.ex`
- [x] T014 [US1] Implement TCP query execution with :gen_tcp (packet: 2) in `dns_client.ex`
- [x] T015 [US1] Implement DNS response parsing with DNS.Message.from_iodata/1 in `dns_client.ex`
- [x] T016 [P] [US1] Create DNS tab component with form in `lib/yellow_dog/console/live/diagnostics_live/dns_tab.ex`
- [x] T017 [US1] Implement DNS form fields (query_name, record_type, server, port, protocol, recursion, timeout) in `dns_tab.ex`
- [x] T018 [US1] Implement form validation for DNS tab in `dns_tab.ex`
- [x] T019 [US1] Implement send_query handler with start_async/3 for DNS in `diagnostics_live.ex`
- [x] T020 [US1] Implement handle_async for DNS query results in `diagnostics_live.ex`
- [x] T021 [US1] Implement DNS query history management (add, restore, clear) in `diagnostics_live.ex`
- [x] T022 [US1] Add error handling for DNS socket errors and timeouts in `dns_client.ex`

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 5 - Response Display and Copy (Priority: P2)

**Goal**: View responses in struct and raw hex formats, copy to clipboard

**Independent Test**: After any query, toggle between struct and raw views. Click copy button and verify clipboard content.

**Note**: US5 is prioritized before US2 because display/copy functionality is needed by all tabs.

### Implementation for User Story 5

- [x] T023 [US5] Implement struct view formatting using inspect(struct, pretty: true) in `result_display.ex`
- [x] T024 [US5] Implement raw view integration with HexDump component in `result_display.ex`
- [x] T025 [US5] Implement xxd-style formatting (offset, hex, ASCII) in `hex_formatter.ex`
- [x] T026 [US5] Add copy-to-clipboard buttons for request and response in `result_display.ex`
- [x] T027 [US5] Implement copied event handler with flash notification in `diagnostics_live.ex`
- [x] T028 [US5] Handle empty response display (timeout/error states) in `result_display.ex`

**Checkpoint**: Display and copy functionality works across all tabs

---

## Phase 5: User Story 2 - mDNS Service Discovery Testing (Priority: P2)

**Goal**: Send mDNS queries to discover local services on multicast 224.0.0.251:5353

**Independent Test**: Enter service type like "_http._tcp.local", click send, see multiple responses from mDNS responders with source addresses until timeout.

### Implementation for User Story 2

- [x] T029 [P] [US2] Create MdnsClient module with query/1 function in `lib/yellow_dog/console/diagnostics/mdns_client.ex`
- [x] T030 [US2] Implement mDNS multicast socket setup with multicast_ttl and multicast_loop in `mdns_client.ex`
- [x] T031 [US2] Implement response collection loop until timeout in `mdns_client.ex`
- [x] T032 [US2] Implement multiple response handling with source addresses in `mdns_client.ex`
- [x] T033 [P] [US2] Create mDNS tab component with form in `lib/yellow_dog/console/live/diagnostics_live/mdns_tab.ex`
- [x] T034 [US2] Implement mDNS form fields (service_type, query_type, timeout) in `mdns_tab.ex`
- [x] T035 [US2] Implement form validation for mDNS tab in `mdns_tab.ex`
- [x] T036 [US2] Implement send_query handler with start_async/3 for mDNS in `diagnostics_live.ex`
- [x] T037 [US2] Implement handle_async for mDNS query results (multiple sources) in `diagnostics_live.ex`
- [x] T038 [US2] Display multiple mDNS responses with source addresses in ResultDisplay in `mdns_tab.ex`

**Checkpoint**: mDNS service discovery works independently

---

## Phase 6: User Story 3 - DHCPv4 Message Testing (Priority: P3)

**Goal**: Send DHCPv4 messages (DISCOVER, REQUEST, etc.) to test DHCP server via broadcast 255.255.255.255:67

**Independent Test**: Configure DISCOVER message with MAC address, click send, see OFFER response. Privileged port warning displayed.

### Implementation for User Story 3

- [x] T039 [P] [US3] Create Dhcpv4Client module with query/1 function in `lib/yellow_dog/console/diagnostics/dhcpv4_client.ex`
- [x] T040 [US3] Implement DHCPv4 message building using DHCPv4.Client utilities in `dhcpv4_client.ex`
- [x] T041 [US3] Implement broadcast UDP socket setup with :gen_udp (port 68) in `dhcpv4_client.ex`
- [x] T042 [US3] Implement DHCPv4 response parsing with DHCPv4.Message.from_iodata/1 in `dhcpv4_client.ex`
- [x] T043 [P] [US3] Create DHCPv4 tab component with form in `lib/yellow_dog/console/live/diagnostics_live/dhcpv4_tab.ex`
- [x] T044 [US3] Implement DHCPv4 form fields (message_type, client_mac, xid, options, timeout) in `dhcpv4_tab.ex`
- [x] T045 [US3] Add privileged port warning alert to DHCPv4 tab in `dhcpv4_tab.ex`
- [x] T046 [US3] Implement auto-generation for MAC and transaction_id fields in `dhcpv4_client.ex`
- [x] T047 [US3] Implement send_query handler with start_async/3 for DHCPv4 in `diagnostics_live.ex`
- [x] T048 [US3] Handle EACCES error with user-friendly message for privileged port in `diagnostics_live.ex`

**Checkpoint**: DHCPv4 testing works independently (requires root for actual execution)

---

## Phase 7: User Story 4 - DHCPv6 Message Testing (Priority: P4)

**Goal**: Send DHCPv6 messages (SOLICIT, REQUEST, etc.) to test DHCPv6 server via multicast ff02::1:2 port 547

**Independent Test**: Configure SOLICIT message with DUID, click send, see ADVERTISE response. Privileged port warning displayed.

### Implementation for User Story 4

- [x] T049 [P] [US4] Create Dhcpv6Client module with query/1 function in `lib/yellow_dog/console/diagnostics/dhcpv6_client.ex`
- [x] T050 [US4] Implement DHCPv6 message building using DHCPv6.Client utilities in `dhcpv6_client.ex`
- [x] T051 [US4] Implement IPv6 multicast socket setup with :socket (port 546) in `dhcpv6_client.ex`
- [x] T052 [US4] Implement DHCPv6 response parsing with DHCPv6.Message.from_iodata/1 in `dhcpv6_client.ex`
- [x] T053 [P] [US4] Create DHCPv6 tab component with form in `lib/yellow_dog/console/live/diagnostics_live/dhcpv6_tab.ex`
- [x] T054 [US4] Implement DHCPv6 form fields (message_type, duid, xid, iaid, options, timeout) in `dhcpv6_tab.ex`
- [x] T055 [US4] Add privileged port warning alert to DHCPv6 tab in `dhcpv6_tab.ex`
- [x] T056 [US4] Implement auto-generation for DUID, xid, and IAID fields using DHCP.SecureRandom in `dhcpv6_client.ex`
- [x] T057 [US4] Implement send_query handler with start_async/3 for DHCPv6 in `diagnostics_live.ex`
- [x] T058 [US4] Handle EACCES error with user-friendly message for privileged port in `diagnostics_live.ex`

**Checkpoint**: DHCPv6 testing works independently (requires root for actual execution)

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T059 [P] Add unit tests for HexFormatter in `test/yellow_dog/console/diagnostics/hex_formatter_test.exs`
- [x] T060 [P] Add unit tests for DnsClient message building in `test/yellow_dog/console/diagnostics/dns_client_test.exs`
- [x] T061 [P] Add unit tests for MdnsClient message building in `test/yellow_dog/console/diagnostics/mdns_client_test.exs`
- [x] T062 [P] Add unit tests for Dhcpv4Client message building in `test/yellow_dog/console/diagnostics/dhcpv4_client_test.exs`
- [x] T063 [P] Add unit tests for Dhcpv6Client message building in `test/yellow_dog/console/diagnostics/dhcpv6_client_test.exs`
- [x] T064 Add LiveView integration tests for tab navigation in `test/yellow_dog/console/live/diagnostics_live_test.exs`
- [x] T065 Verify code compiles with --warnings-as-errors
- [x] T066 Run mix format and mix credo --strict

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Foundational phase completion
  - US1 (DNS) → can start after Phase 2
  - US5 (Display) → can start after Phase 2, recommended before US2
  - US2 (mDNS) → can start after Phase 2
  - US3 (DHCPv4) → can start after Phase 2
  - US4 (DHCPv6) → can start after Phase 2
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 5 (P2)**: Can start after Foundational - Display components used by all tabs
- **User Story 2 (P2)**: Can start after Foundational - Independent of US1, uses shared components
- **User Story 3 (P3)**: Can start after Foundational - Independent of US1/US2
- **User Story 4 (P4)**: Can start after Foundational - Independent of other stories

### Within Each User Story

- Client module before tab component
- Form implementation before event handlers
- Core functionality before error handling
- Story complete before moving to next priority

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel (T002, T003, T004)
- All Foundational tasks marked [P] can run in parallel (T006, T007, T008)
- Client modules across stories can be built in parallel (T011, T029, T039, T049)
- Tab components across stories can be built in parallel (T016, T033, T043, T053)
- All test tasks in Polish phase can run in parallel (T059-T063)

---

## Parallel Example: Phase 2 Foundational

```bash
# Launch all foundational components together:
Task T006: "Create ResultDisplay component in components/result_display.ex"
Task T007: "Create HexDump component in components/hex_dump.ex"
Task T008: "Create QueryHistory component in components/query_history.ex"
```

## Parallel Example: Client Modules Across Stories

```bash
# After Foundational phase, launch all client modules:
Task T011: "[US1] Create DnsClient module in diagnostics/dns_client.ex"
Task T029: "[US2] Create MdnsClient module in diagnostics/mdns_client.ex"
Task T039: "[US3] Create Dhcpv4Client module in diagnostics/dhcpv4_client.ex"
Task T049: "[US4] Create Dhcpv6Client module in diagnostics/dhcpv6_client.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T010)
3. Complete Phase 3: User Story 1 - DNS (T011-T022)
4. Complete Phase 4: User Story 5 - Display (T023-T028)
5. **STOP and VALIDATE**: Test DNS queries with struct/raw views
6. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 (DNS) → Test independently → Deploy (MVP!)
3. Add User Story 5 (Display) → Enhanced view/copy functionality
4. Add User Story 2 (mDNS) → Test independently → Deploy
5. Add User Story 3 (DHCPv4) → Test independently → Deploy
6. Add User Story 4 (DHCPv6) → Test independently → Deploy
7. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (DNS) + User Story 5 (Display)
   - Developer B: User Story 2 (mDNS)
   - Developer C: User Story 3 (DHCPv4) + User Story 4 (DHCPv6)
3. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- DHCP stories require root privileges for actual network testing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All paths relative to `apps/yellow_dog_console/`
