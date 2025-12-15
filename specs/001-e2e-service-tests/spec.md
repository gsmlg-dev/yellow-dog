# Feature Specification: E2E Service Tests

**Feature Branch**: `001-e2e-service-tests`
**Created**: 2025-12-15
**Status**: Draft
**Input**: User description: "We need to add e2e test for the service dns, dhcpv4, dhcpv6 and mdns, these e2e tests should be Standalone GitHub Actions. We need e2e tests like these: test.e2e (run all), test.e2e.dns, test.e2e.mdns, test.e2e.dhcpv4, test.e2e.dhcpv6. All e2e test should start service and run the tests in their custom content. E2e tests should be placed at ./e2e_test/ dir."

## Clarifications

### Session 2025-12-15

- Q: How should mDNS E2E tests handle multicast in CI environments? → A: Use unicast queries to loopback (127.0.0.1:5353)
- Q: How should E2E tests handle port conflicts? → A: Auto-select available port (port 0, OS assigns)
- Q: How should E2E tests handle transient failures on service startup? → A: Wait for service ready signal before any queries

## User Scenarios & Testing *(mandatory)*

### User Story 1 - DNS Service E2E Testing (Priority: P1)

As a developer, I want to run end-to-end tests for the DNS service that start the actual DNS server and verify it responds correctly to DNS queries, so I can ensure the DNS service works correctly in a production-like environment.

**Why this priority**: DNS is the core service of Yellow Dog. Ensuring DNS works end-to-end is critical for the project's primary functionality.

**Independent Test**: Can be fully tested by starting the DNS server on a non-privileged port (e.g., 5353) and sending actual DNS queries using standard tools (dig, nslookup) or Elixir DNS client.

**Acceptance Scenarios**:

1. **Given** the DNS service is configured with a test zone, **When** I run `mix test.e2e.dns`, **Then** the DNS server starts, responds to A record queries, and the test passes.
2. **Given** the DNS service is running, **When** I query for an existing domain in the test zone, **Then** the correct IP address is returned.
3. **Given** the DNS service is running, **When** I query for a non-existent domain, **Then** an NXDOMAIN response is returned.

---

### User Story 2 - mDNS Service E2E Testing (Priority: P2)

As a developer, I want to run end-to-end tests for the mDNS service that start the actual mDNS responder and verify it announces and responds to service discovery queries, so I can ensure the mDNS service works correctly for local network service discovery.

**Why this priority**: mDNS is essential for local network service discovery (Bonjour/Zeroconf). It's the second most commonly used service.

**Independent Test**: Can be fully tested by starting the mDNS service, registering a test service, and verifying it responds to multicast DNS queries on the .local domain.

**Acceptance Scenarios**:

1. **Given** the mDNS service is configured, **When** I run `mix test.e2e.mdns`, **Then** the mDNS server starts and registers test services.
2. **Given** the mDNS service is running with a registered service, **When** I send a PTR query for `_http._tcp.local`, **Then** the service is discovered.
3. **Given** the mDNS service is running, **When** I query for a registered service's SRV record, **Then** the correct host and port are returned.

---

### User Story 3 - DHCPv4 Service E2E Testing (Priority: P3)

As a developer, I want to run end-to-end tests for the DHCPv4 service that start the actual DHCP server and verify it can complete a DHCP handshake, so I can ensure the DHCPv4 service correctly allocates IP addresses.

**Why this priority**: DHCPv4 is a standard network service. Testing it ensures IP address allocation works correctly.

**Independent Test**: Can be fully tested by starting the DHCPv4 server on a non-privileged port and simulating a DHCP DISCOVER/OFFER/REQUEST/ACK handshake.

**Acceptance Scenarios**:

1. **Given** the DHCPv4 service is configured with an address pool, **When** I run `mix test.e2e.dhcpv4`, **Then** the DHCP server starts successfully.
2. **Given** the DHCPv4 service is running, **When** I send a DHCP DISCOVER message, **Then** a DHCP OFFER with a valid IP address is returned.
3. **Given** the DHCPv4 service offered an IP, **When** I send a DHCP REQUEST, **Then** a DHCP ACK is returned and the lease is recorded.

---

### User Story 4 - DHCPv6 Service E2E Testing (Priority: P4)

As a developer, I want to run end-to-end tests for the DHCPv6 service that start the actual DHCPv6 server and verify it can complete a DHCPv6 handshake, so I can ensure the DHCPv6 service correctly allocates IPv6 addresses.

**Why this priority**: DHCPv6 is similar to DHCPv4 but for IPv6 networks. It's important for IPv6-enabled environments.

**Independent Test**: Can be fully tested by starting the DHCPv6 server and simulating a SOLICIT/ADVERTISE/REQUEST/REPLY handshake.

**Acceptance Scenarios**:

1. **Given** the DHCPv6 service is configured with an IPv6 address pool, **When** I run `mix test.e2e.dhcpv6`, **Then** the DHCPv6 server starts successfully.
2. **Given** the DHCPv6 service is running, **When** I send a SOLICIT message, **Then** an ADVERTISE with a valid IPv6 address is returned.
3. **Given** the DHCPv6 service advertised an IPv6, **When** I send a REQUEST, **Then** a REPLY is returned and the lease is recorded.

---

### User Story 5 - Run All E2E Tests (Priority: P5)

As a developer, I want to run all E2E tests with a single command, so I can verify all services work correctly before deployment.

**Why this priority**: Running all tests together is a convenience feature once individual tests are working.

**Independent Test**: Can be tested by running `mix test.e2e` which executes all individual service E2E tests sequentially.

**Acceptance Scenarios**:

1. **Given** all E2E test files exist in `e2e_test/` directory, **When** I run `mix test.e2e`, **Then** all service E2E tests are executed.
2. **Given** the E2E tests are configured in CI, **When** a PR is created, **Then** the GitHub Actions workflow runs all E2E tests.

---

### Edge Cases

- What happens when the required port is already in use? Tests use auto-select (port 0) to let the OS assign an available port, eliminating port conflicts.
- How does the system handle tests timing out? Each E2E test should have a configurable timeout (default: 60 seconds).
- What happens when a service fails to start? The test should fail with a clear error message indicating the startup failure.
- How do we handle multicast (mDNS) in CI environments that may not support it? Use unicast queries to loopback (127.0.0.1:5353) instead of multicast.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a `mix test.e2e` command that runs all E2E tests
- **FR-002**: System MUST provide individual E2E test commands: `mix test.e2e.dns`, `mix test.e2e.mdns`, `mix test.e2e.dhcpv4`, `mix test.e2e.dhcpv6`
- **FR-003**: E2E tests MUST be placed in the `e2e_test/` directory
- **FR-004**: Each E2E test MUST start the actual service being tested
- **FR-005**: Each E2E test MUST use auto-selected ports (port 0) to let the OS assign available non-privileged ports, avoiding permission issues and port conflicts in CI
- **FR-006**: E2E tests MUST be runnable as standalone GitHub Actions workflows
- **FR-007**: System MUST provide a GitHub Actions workflow file for E2E tests
- **FR-008**: E2E tests MUST clean up resources (stop services, release ports) after completion
- **FR-009**: E2E tests MUST support configurable timeouts for service startup and queries
- **FR-010**: E2E tests MUST provide clear error messages on failure
- **FR-011**: E2E tests MUST wait for service ready signal before sending any queries to avoid transient startup failures

### Key Entities

- **E2E Test File**: Elixir ExUnit test file in `e2e_test/` directory, contains tests for a specific service
- **E2E Test Helper**: Shared helper module for starting/stopping services and making protocol requests
- **GitHub Actions Workflow**: YAML workflow file defining E2E test jobs
- **Mix Task**: Custom mix tasks for running E2E tests (`test.e2e`, `test.e2e.dns`, etc.)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Running `mix test.e2e` executes all E2E tests and reports results
- **SC-002**: Each individual service E2E test (`mix test.e2e.dns`, etc.) can be run independently
- **SC-003**: E2E tests complete within 2 minutes on standard CI runners
- **SC-004**: GitHub Actions E2E workflow passes on the main branch
- **SC-005**: E2E tests detect service failures (e.g., wrong responses, startup failures) with clear error messages
- **SC-006**: E2E tests do not leave orphaned processes or open ports after completion
