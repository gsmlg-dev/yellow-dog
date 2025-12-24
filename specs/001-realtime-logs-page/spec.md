# Feature Specification: Real-time Logs Page

**Feature Branch**: `001-realtime-logs-page`
**Created**: 2025-12-24
**Status**: Draft
**Input**: User description: "We are going to implement the console's page '/logs' at this page, it should support attach logs (can select log module) and show realtime logs, it only show realtime log!"

## Clarifications

### Session 2025-12-24

- Q: How should log entry metadata (extra fields like domain, IP, duration) be displayed? → A: Show metadata on hover/expand (click or hover to reveal details)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Real-time System Logs (Priority: P1)

As a system administrator, I want to view real-time log output from YellowDog services so that I can monitor system activity and troubleshoot issues as they occur.

**Why this priority**: This is the core functionality of the logs page. Without real-time log viewing, the page has no purpose. Users need immediate visibility into system events to effectively monitor and debug the services.

**Independent Test**: Can be fully tested by opening the logs page and verifying that log entries appear in real-time as system events occur. Delivers immediate value for monitoring and troubleshooting.

**Acceptance Scenarios**:

1. **Given** I am on the /logs page, **When** a log event occurs in any YellowDog service, **Then** the log entry appears immediately in the log viewer without page refresh
2. **Given** the page is open, **When** multiple log events occur in rapid succession, **Then** all events are displayed in chronological order with newest entries appearing at the bottom
3. **Given** the log viewer is active, **When** a new log entry arrives, **Then** the viewer automatically scrolls to show the latest entry (unless user has scrolled up)
4. **Given** the page is open, **When** I have been viewing logs for an extended period, **Then** older log entries are automatically removed to maintain performance (keep last 500-1000 entries)

---

### User Story 2 - Filter Logs by Module/Application (Priority: P2)

As a system administrator, I want to filter logs by specific YellowDog modules/applications so that I can focus on relevant log output without noise from other services.

**Why this priority**: Filtering is essential for usability when multiple services are running simultaneously. Without filtering, the log output would be overwhelming and finding relevant information would be difficult.

**Independent Test**: Can be tested by selecting specific modules from the filter controls and verifying only logs from those modules appear. Delivers focused troubleshooting capability.

**Acceptance Scenarios**:

1. **Given** I am on the /logs page, **When** I view the module filter controls, **Then** I see all available YellowDog modules (DNS, DHCPv4, DHCPv6, mDNS, Console, Core)
2. **Given** I have selected only the DNS module in the filter, **When** log events occur from DNS and other modules, **Then** only DNS log entries are displayed
3. **Given** I have selected multiple modules (DNS and DHCPv4), **When** log events occur from all modules, **Then** only events from the selected modules are displayed
4. **Given** I have no modules selected, **When** I view the logs, **Then** all log entries from all modules are displayed (no filtering)
5. **Given** I am viewing filtered logs, **When** I change the filter selection, **Then** the log view immediately updates to reflect the new filter (existing entries not matching are hidden)

---

### User Story 3 - Filter Logs by Severity Level (Priority: P3)

As a system administrator, I want to filter logs by severity level (debug, info, warning, error) so that I can focus on issues of a particular importance.

**Why this priority**: Log level filtering enhances usability but is not critical for basic functionality. Users can work with all logs if needed, but level filtering improves the experience when looking for specific types of issues.

**Independent Test**: Can be tested by selecting a minimum log level and verifying only logs at or above that level appear. Delivers efficient issue identification.

**Acceptance Scenarios**:

1. **Given** I am on the /logs page, **When** I view the log level controls, **Then** I see options for all log levels (Debug, Info, Warning, Error)
2. **Given** I have selected "Warning" as the minimum level, **When** log events occur at all levels, **Then** only Warning and Error level entries are displayed
3. **Given** I have selected "Debug" as the minimum level, **When** log events occur, **Then** all log entries are displayed regardless of level
4. **Given** I am viewing filtered logs by level, **When** I change the level selection, **Then** the log view immediately updates to reflect the new minimum level

---

### User Story 4 - Control Log Streaming (Priority: P3)

As a system administrator, I want to pause and resume the real-time log stream so that I can examine specific log entries without them scrolling away.

**Why this priority**: Stream control is a convenience feature that enhances user experience when analyzing logs but is not essential for basic monitoring functionality.

**Independent Test**: Can be tested by clicking pause, generating logs, and verifying new logs are buffered but not displayed until resumed.

**Acceptance Scenarios**:

1. **Given** I am viewing the real-time log stream, **When** I click the pause button, **Then** the log display stops updating and new entries are buffered
2. **Given** the log stream is paused, **When** new log events occur, **Then** the buffered count indicator shows how many new entries are waiting
3. **Given** the log stream is paused with buffered entries, **When** I click resume, **Then** all buffered entries appear and real-time streaming resumes
4. **Given** the log stream is paused, **When** I click clear, **Then** the current log display is cleared (buffered entries are preserved)

---

### Edge Cases

- What happens when no log events are occurring? The page displays an empty log viewer with a message indicating it's waiting for log events.
- What happens when the user loses WebSocket connection? The page shows a disconnection indicator and attempts to reconnect automatically, resuming log streaming when reconnected.
- What happens when too many logs are generated (log flood)? The viewer implements rate limiting (max 100 entries/second displayed) and drops oldest entries beyond buffer limit.
- What happens when the user navigates away and returns? The log buffer is cleared; only new real-time events from reconnection are shown.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a /logs route accessible from the web console navigation
- **FR-002**: System MUST establish a real-time connection (WebSocket via LiveView) for log event streaming
- **FR-003**: System MUST display log entries with timestamp, log level, module/app source, and message content; optional metadata (e.g., domain, IP, duration) MUST be accessible via hover or expand interaction
- **FR-004**: System MUST provide module/application filter controls with checkboxes for: DNS, DHCPv4, DHCPv6, mDNS, Console, and Core (yellow_dog)
- **FR-005**: System MUST provide log level filter with options: Debug, Info, Warning, Error (where selecting a level shows that level and above)
- **FR-006**: System MUST apply filters in real-time as log entries arrive (client-side filtering of streamed events)
- **FR-007**: System MUST provide pause/resume controls for the log stream
- **FR-008**: System MUST provide a clear button to empty the current log display
- **FR-009**: System MUST limit the displayed log buffer to a maximum of 1000 entries to maintain browser performance
- **FR-010**: System MUST auto-scroll to newest entries unless the user has manually scrolled up
- **FR-011**: System MUST visually distinguish log levels using color coding (e.g., debug=gray, info=blue, warning=amber, error=red)
- **FR-012**: System MUST integrate with the existing YellowDog.Telemetry log event system ([:yellow_dog, :log, level] events)
- **FR-013**: System MUST show a connection status indicator (connected/disconnected/reconnecting)
- **FR-014**: System MUST be consistent with existing console UI patterns (DaisyUI components, dark mode support)

### Key Entities

- **Log Entry**: Represents a single log event with: timestamp, level (debug/info/warning/error), app source (dns/dhcpv4/dhcpv6/mdns/console/core), module name, message, and optional metadata (displayed on hover/expand)
- **Filter State**: The current filter configuration including selected modules (list), minimum log level, and stream status (running/paused)
- **Log Buffer**: The collection of log entries currently displayed, capped at maximum size with FIFO eviction

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can view real-time log output within 100 milliseconds of events occurring
- **SC-002**: Log filtering by module applies instantly (no perceptible delay when toggling module filters)
- **SC-003**: The logs page maintains smooth scrolling and interaction with up to 1000 displayed log entries
- **SC-004**: Users can pause the log stream, examine entries, and resume without losing buffered events
- **SC-005**: The page correctly displays log entries from all 6 YellowDog modules when no filters are applied
- **SC-006**: Connection recovery occurs automatically within 5 seconds of network restoration
- **SC-007**: Log level colors are visually distinct and follow the existing console color scheme for consistency
- **SC-008**: The logs page navigation item is accessible from the sidebar like other console pages

## Assumptions

- LiveView's built-in WebSocket connection provides sufficient real-time performance for log streaming
- The YellowDog.Telemetry module emits log events via telemetry that can be subscribed to
- The existing DaisyUI component library provides adequate primitives for log display styling
- Browser memory is sufficient to hold 1000 log entries without performance degradation
- Log events include the `app` field to enable module filtering
- PubSub or similar mechanism exists for broadcasting log events to connected LiveView processes
