# Feature Specification: Telemetry-Based Logging System

**Feature Branch**: `001-telemetry-logging`
**Created**: 2025-12-22
**Status**: Draft
**Input**: User description: "please update logging system use yellow_dog_telemetry"

## Overview

Migrate all application logging from direct `Logger` module calls to a centralized telemetry-based logging system using `yellow_dog_telemetry`. This change ensures all logging flows through telemetry events, enabling centralized observability, structured logging, consistent metrics, and configurable verbosity without code changes.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Centralized Log Handler Attachment (Priority: P1)

As a system administrator, I want all log output to be controlled through telemetry handler attachment so that I can enable, disable, or reconfigure logging behavior without modifying application code.

**Why this priority**: This is the foundation of the new logging system. Without centralized handler attachment, telemetry events would emit but produce no log output.

**Independent Test**: Can be fully tested by starting the application and verifying that telemetry events produce log output through attached handlers.

**Acceptance Scenarios**:

1. **Given** the application starts, **When** `YellowDog.Telemetry.attach_logger_handlers/0` is called, **Then** all telemetry events with log-worthy data produce corresponding Logger output
2. **Given** logger handlers are attached, **When** a DNS query is processed, **Then** an info-level log message appears with query details
3. **Given** logger handlers are attached, **When** a DHCP lease is granted, **Then** an info-level log message appears with lease details
4. **Given** logger handlers are NOT attached, **When** telemetry events fire, **Then** no log output is produced (silent operation)

---

### User Story 2 - Protocol Service Telemetry Events (Priority: P1)

As a developer, I want all protocol services (DNS, DHCP, mDNS) to emit telemetry events instead of direct Logger calls so that logging is decoupled from the output mechanism.

**Why this priority**: This is equally critical as P1 - telemetry events are the source of all logging data.

**Independent Test**: Can be tested by attaching a test handler to telemetry events and verifying events fire during protocol operations.

**Acceptance Scenarios**:

1. **Given** a DNS query is received, **When** the handler processes it, **Then** a `[:yellow_dog, :dns, :query, :received]` event is emitted with query metadata
2. **Given** a DNS query completes, **When** the response is sent, **Then** a `[:yellow_dog, :dns, :query, :completed]` event is emitted with duration and result metadata
3. **Given** a DNS error occurs, **When** the error is handled, **Then** a `[:yellow_dog, :dns, :query, :error]` event is emitted with error details
4. **Given** a DHCP lease request is received, **When** processing begins, **Then** a `[:yellow_dog, :dhcpv4, :lease, :requested]` event is emitted
5. **Given** a DHCP lease is granted, **When** allocation completes, **Then** a `[:yellow_dog, :dhcpv4, :lease, :granted]` event is emitted with IP and MAC address
6. **Given** an mDNS service is registered, **When** registration completes, **Then** a `[:yellow_dog, :mdns, :service, :registered]` event is emitted

---

### User Story 3 - Migrate Existing Logger Calls (Priority: P2)

As a maintainer, I want all existing direct Logger calls in the codebase to be replaced with telemetry events so that the codebase follows the new logging standard.

**Why this priority**: Depends on P1 infrastructure being in place. Required for consistency but can be done incrementally.

**Independent Test**: Can be tested by searching the codebase for `Logger.` calls and verifying only approved uses remain.

**Acceptance Scenarios**:

1. **Given** the migration is complete, **When** searching for `Logger.info`, `Logger.warn`, `Logger.error`, `Logger.debug` in protocol apps, **Then** zero direct calls are found (excluding yellow_dog_telemetry handlers)
2. **Given** the migration is complete, **When** running the application, **Then** all previous log messages are still produced via telemetry handlers
3. **Given** an existing Logger.error call for connection failure, **When** migrated, **Then** equivalent telemetry event produces the same log output

---

### User Story 4 - Log Level Configuration (Priority: P3)

As a system administrator, I want to configure log verbosity per service through telemetry handler configuration so that I can focus on relevant logs during debugging.

**Why this priority**: Nice-to-have enhancement once core system is working.

**Independent Test**: Can be tested by modifying handler configuration and verifying only specified log levels appear.

**Acceptance Scenarios**:

1. **Given** DNS handler is configured for `:debug` level, **When** DNS events fire, **Then** debug, info, warning, and error logs appear
2. **Given** DHCP handler is configured for `:error` level, **When** DHCP events fire, **Then** only error logs appear
3. **Given** default handler configuration, **When** events fire, **Then** info-level and above logs appear

---

### Edge Cases

- What happens when telemetry handler crashes during event processing? (Should not affect service operation)
- How does system handle high-volume event emission? (Telemetry is designed for minimal overhead)
- What happens when Logger backend is unavailable? (Events still emit, handlers fail gracefully)
- How are structured metadata fields handled in log output? (Should be formatted consistently)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST emit telemetry events for all loggable actions instead of direct Logger calls
- **FR-002**: System MUST provide `YellowDog.Telemetry.attach_logger_handlers/0` function to attach Logger handlers to all relevant telemetry events
- **FR-003**: System MUST call `attach_logger_handlers/0` during application startup in `YellowDog.Application.start/2`
- **FR-004**: All telemetry events MUST follow the naming convention `[:yellow_dog, <service>, <resource>, <action>]`
- **FR-005**: All telemetry events MUST include relevant metadata (timestamps, identifiers, context)
- **FR-006**: Logger handlers MUST use lazy log message formatting (fn -> message end) for performance
- **FR-007**: System MUST NOT have direct Logger calls in protocol applications (dns, dhcpv4, dhcpv6, mdns) except within yellow_dog_telemetry handlers
- **FR-008**: Each service MUST emit events for: request received, request completed, and errors
- **FR-009**: System MUST support detaching handlers for testing purposes via `YellowDog.Telemetry.detach_logger_handlers/0`
- **FR-010**: Telemetry handlers MUST NOT crash or raise exceptions that affect service operation

### Key Entities

- **Telemetry Event**: A tuple of event name, measurements map, and metadata map representing a loggable action
- **Logger Handler**: A function attached to telemetry events that formats and outputs log messages
- **Event Metadata**: Structured data accompanying each event (query details, client info, timestamps, error reasons)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All log messages previously produced by the application are still produced after migration (100% log parity)
- **SC-002**: Zero direct Logger calls exist in protocol applications after migration (verified by code search)
- **SC-003**: Application startup time is not measurably affected (within 5% of baseline)
- **SC-004**: Memory overhead per logged event is negligible (telemetry is designed for low overhead)
- **SC-005**: Developers can add new loggable events by emitting telemetry without modifying handler code
- **SC-006**: Administrators can disable all logging by not attaching handlers (silent mode)
- **SC-007**: Test suites can attach custom handlers to verify event emission without polluting test output

## Assumptions

- The `yellow_dog_telemetry` package already exists and provides the telemetry dependency
- Elixir's `:telemetry` library is already a project dependency
- The project follows the constitution's telemetry event naming convention
- Performance impact of telemetry is acceptable (telemetry library is designed for minimal overhead)
- Logger handlers are only called when log level is appropriate (standard Logger behavior)

## Scope

### In Scope

- Adding `attach_logger_handlers/0` and `detach_logger_handlers/0` to `YellowDog.Telemetry`
- Implementing logger handler functions for all service events
- Migrating existing Logger calls in yellow_dog_dns, yellow_dog_dhcpv4, yellow_dog_dhcpv6, yellow_dog_mdns
- Updating application startup to attach handlers
- Adding tests for telemetry event emission and handler behavior

### Out of Scope

- Modifying infrastructure libraries (abyss, ex_dns, ex_dhcp) - they have their own logging
- Implementing log aggregation or external log shipping
- Adding new log messages beyond what currently exists
- Changing log format or structure beyond what telemetry provides
- Web console logging (Phoenix has its own telemetry integration)
