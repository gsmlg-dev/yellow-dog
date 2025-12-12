# Feature Specification: DNS Service Implementation Fix and Dashboard Service Controls

**Feature Branch**: `001-dns-service`
**Created**: 2025-12-10
**Status**: Draft
**Input**: User description: "Please implement the dns service, the dns service it can not be started right now, find out why it fails to start, fix it and add service start / stop control in page /dashboard."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start DNS Service from Dashboard (Priority: P1)

As an administrator, I want to start the DNS service from the dashboard so that I can enable DNS resolution capabilities without manually editing configuration files or restarting the application.

**Why this priority**: Core functionality - the DNS service must be able to start successfully before any other DNS-related features can work. This is the blocking issue preventing DNS from functioning.

**Independent Test**: Can be fully tested by clicking "Start" on the DNS service card in the dashboard and verifying the service transitions to "Running" state and responds to DNS queries.

**Acceptance Scenarios**:

1. **Given** the DNS service is stopped, **When** I click the "Start" button on the DNS service card, **Then** the service status changes to "Running" within 5 seconds and the button changes to "Stop"
2. **Given** the DNS service is disabled in configuration, **When** I view the dashboard, **Then** I see the DNS service with an "Enable" option or clear indication it's disabled
3. **Given** the DNS service fails to start, **When** the start operation fails, **Then** I see a clear error message explaining the failure reason

---

### User Story 2 - Stop DNS Service from Dashboard (Priority: P2)

As an administrator, I want to stop the DNS service from the dashboard so that I can gracefully shut down DNS resolution when needed (e.g., for maintenance or when another DNS server is preferred).

**Why this priority**: Essential for service lifecycle management. Once the service can start, administrators need the ability to stop it.

**Independent Test**: Can be fully tested by clicking "Stop" on a running DNS service and verifying it stops accepting queries.

**Acceptance Scenarios**:

1. **Given** the DNS service is running, **When** I click the "Stop" button, **Then** the service status changes to "Stopped" within 5 seconds
2. **Given** the DNS service is processing queries, **When** I stop the service, **Then** in-flight queries are completed or gracefully rejected before shutdown
3. **Given** the DNS service is stopped, **When** I view the dashboard, **Then** the "Start" button is available and "Stop" is disabled or hidden

---

### User Story 3 - View DNS Service Status on Dashboard (Priority: P2)

As an administrator, I want to see the current status of the DNS service on the dashboard so that I can monitor service health and availability at a glance.

**Why this priority**: Visibility into service state is essential for operations and troubleshooting.

**Independent Test**: Can be fully tested by viewing the dashboard and confirming DNS service status accurately reflects the actual service state.

**Acceptance Scenarios**:

1. **Given** the DNS service is running, **When** I view the dashboard, **Then** I see a "Running" status indicator with green visual styling
2. **Given** the DNS service is stopped, **When** I view the dashboard, **Then** I see a "Stopped" status indicator with appropriate visual styling
3. **Given** the DNS service experiences an error, **When** I view the dashboard, **Then** I see an "Error" status with a brief description

---

### User Story 4 - Consistent Service Controls Across All Services (Priority: P3)

As an administrator, I want all services (DNS, mDNS, DHCPv4, DHCPv6) to have consistent start/stop controls on the dashboard so that I can manage all services uniformly.

**Why this priority**: Ensures a consistent user experience across the platform. Lower priority because individual service control is functional; this adds uniformity.

**Independent Test**: Can be fully tested by verifying each service card has identical control patterns (Start/Stop buttons, status indicators) and behaves consistently.

**Acceptance Scenarios**:

1. **Given** I am on the dashboard, **When** I view service cards for DNS, mDNS, DHCPv4, and DHCPv6, **Then** all cards have the same layout and control options
2. **Given** any service is running, **When** I click its Stop button, **Then** the behavior is consistent with other services (same response time, same visual feedback)

---

### Edge Cases

- What happens when the DNS port (53) is already in use by another process? System displays clear error message indicating port conflict.
- What happens when the user lacks permission to bind to privileged port 53? System displays permission error and suggests running with elevated privileges or using a non-privileged port.
- What happens if the configuration file is corrupted or missing? System uses default configuration values and displays a warning about missing/invalid config.
- What happens if starting DNS service while dependent zone files are missing? System starts with empty zones and logs a warning, allowing basic resolution.
- What happens if the service crashes immediately after starting? Dashboard shows "Error" state with last error message; rapid restart attempts are rate-limited.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST start the DNS service when the "Start" action is triggered from the dashboard
- **FR-002**: System MUST stop the DNS service gracefully when the "Stop" action is triggered from the dashboard
- **FR-003**: System MUST display accurate DNS service status (Running, Stopped, Error) on the dashboard
- **FR-004**: System MUST provide visual feedback (button state changes, status updates) within 5 seconds of service state changes
- **FR-005**: System MUST display meaningful error messages when service operations fail
- **FR-006**: System MUST manage DNS child processes (ViewManager, ConfigWatcher) within the supervisor tree
- **FR-007**: System MUST ensure DNS service architecture follows the same patterns as working services (mDNS, DHCPv4)
- **FR-008**: System MUST handle DNS service startup without returning `:ignore` when service is disabled (filtering happens at application level)
- **FR-009**: System MUST properly link all child processes started by DNS service for crash detection
- **FR-010**: System MUST synchronize child process startup to ensure dependencies are ready before the DNS server accepts queries

### Key Entities

- **DNS Service**: The DNS resolver service that handles DNS queries, composed of Server, Handler, ViewManager, and Cache components
- **Service Card**: Dashboard UI component displaying service name, status, and control buttons (Start/Stop)
- **Service Status**: Current state of a service (Running, Stopped, Error, Disabled) with associated metadata (uptime, error message)
- **View Manager**: DNS component managing DNS views and zones for query resolution

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: DNS service successfully starts when enabled and "Start" is clicked, confirmed by service responding to queries
- **SC-002**: Service status updates reflect on dashboard within 5 seconds of actual state changes
- **SC-003**: DNS service survives child process crashes and auto-recovers without administrator intervention
- **SC-004**: All service control actions (start/stop) complete or show error feedback within 10 seconds
- **SC-005**: Dashboard shows consistent UI patterns across all four services (DNS, mDNS, DHCPv4, DHCPv6)
- **SC-006**: DNS service can handle 100 concurrent queries without crashing after being started from dashboard

## Assumptions

- The DNS service will use port 53 by default (or a configured alternative port)
- The application runs with sufficient privileges to bind to port 53 (or test environment uses non-privileged ports)
- The existing Abyss UDP library and ex_dns protocol library are functioning correctly
- The dashboard uses Phoenix LiveView and can receive real-time updates via PubSub
- Working services (mDNS, DHCPv4, DHCPv6) provide the architectural patterns to follow
- Service state persistence is not required - services start in "stopped" state on application restart unless auto-start is configured
