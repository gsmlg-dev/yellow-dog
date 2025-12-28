# Feature Specification: Process Map

**Feature Branch**: `001-process-map`
**Created**: 2024-12-28
**Status**: Draft
**Input**: User description: "in the left menu, under system section, add a new menu, process map. In this map, show the erlang actor process tree diagram, each tree node can be click to show their status"

## Clarifications

### Session 2024-12-28

- Q: Which processes should the tree display - all BEAM processes or only YellowDog apps? → A: Only YellowDog umbrella applications (yellow_dog, yellow_dog_dns, yellow_dog_dhcpv4, yellow_dog_dhcpv6, yellow_dog_mdns, yellow_dog_console, yellow_dog_telemetry)
- Q: What access control applies to viewing process information? → A: All authenticated console users can view the process map without additional permissions

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Process Tree (Priority: P1)

As a system administrator, I want to see a visual tree diagram of all running Erlang/OTP processes in the system, so that I can understand the supervision hierarchy and identify how processes are organized.

**Why this priority**: This is the core feature - without the tree visualization, nothing else works. Users need to see the process hierarchy before they can interact with individual processes.

**Independent Test**: Can be fully tested by navigating to /process-map and verifying that a tree diagram appears showing the application supervision tree, starting from the root supervisor down to worker processes.

**Acceptance Scenarios**:

1. **Given** the YellowDog application is running, **When** the user clicks "Process Map" in the System section of the sidebar, **Then** the system displays a tree diagram showing the Erlang process hierarchy with the application supervisor at the top.
2. **Given** the process map page is loaded, **When** the user views the tree, **Then** each node displays the process name/identifier in a readable format.
3. **Given** the process map page is loaded, **When** new processes are started or stopped, **Then** the tree diagram updates to reflect the current state within 5 seconds.

---

### User Story 2 - View Process Status on Click (Priority: P2)

As a system administrator, I want to click on any process node in the tree to see its status details, so that I can diagnose issues and understand process behavior.

**Why this priority**: This is the primary interaction mechanism - users will click nodes to get detailed information. This builds on top of the tree visualization.

**Independent Test**: Can be fully tested by clicking on any process node and verifying that a status panel/modal appears with process information.

**Acceptance Scenarios**:

1. **Given** the process map is displayed, **When** the user clicks on a process node, **Then** a status panel shows the process details including: process identifier, status (alive/dead), current function, message queue length, and memory usage.
2. **Given** a process node is clicked, **When** the status panel is displayed, **Then** the user can dismiss it by clicking outside or pressing Escape.
3. **Given** the process status panel is open, **When** the user clicks on a different process node, **Then** the panel updates to show the newly selected process's status.

---

### User Story 3 - Navigate Process Hierarchy (Priority: P3)

As a system administrator, I want to expand and collapse tree branches to focus on specific parts of the process hierarchy, so that I can manage large supervision trees effectively.

**Why this priority**: For large applications with many processes, navigation controls are essential for usability but not required for basic functionality.

**Independent Test**: Can be fully tested by verifying expand/collapse functionality works on supervisor nodes with child processes.

**Acceptance Scenarios**:

1. **Given** a supervisor node has child processes, **When** the user clicks the expand/collapse indicator, **Then** the child processes toggle between visible and hidden states.
2. **Given** all branches are expanded, **When** the user wants to focus on a specific subtree, **Then** they can collapse other branches to reduce visual clutter.
3. **Given** a branch is collapsed, **When** the user expands it, **Then** the child processes are fetched and displayed in the correct hierarchy.

---

### Edge Cases

- What happens when a process terminates while the user is viewing its status panel?
  - The panel should indicate the process has terminated and offer to close or refresh.
- How does the system handle very large supervision trees (100+ processes)?
  - The tree should remain responsive; consider lazy loading or pagination for deeply nested branches.
- What happens when the user navigates to Process Map while some supervisors are restarting?
  - Display the current snapshot with a visual indicator for processes in transient states.
- What if the browser connection is lost while viewing the process map?
  - The standard Phoenix LiveView reconnection behavior applies; tree updates when reconnected.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST add a "Process Map" menu item under the "System" section in the left sidebar navigation.
- **FR-002**: System MUST display the supervision tree for YellowDog umbrella applications only (yellow_dog, yellow_dog_dns, yellow_dog_dhcpv4, yellow_dog_dhcpv6, yellow_dog_mdns, yellow_dog_console, yellow_dog_telemetry) as a visual tree diagram when the user navigates to the Process Map page.
- **FR-003**: Each tree node MUST display the process name or registered name if available, otherwise the process identifier.
- **FR-004**: Each tree node MUST be clickable to reveal process status information.
- **FR-005**: Process status panel MUST display at minimum: process identifier (PID), registered name (if any), current status, current function being executed, message queue length, and memory usage.
- **FR-006**: The process tree MUST show the parent-child relationship between supervisors and their supervised processes.
- **FR-007**: Supervisor nodes MUST be visually distinguishable from worker process nodes.
- **FR-008**: The tree diagram MUST update in near real-time to reflect process changes (starts, stops, crashes, restarts).
- **FR-009**: Users MUST be able to expand and collapse supervisor nodes to show or hide child processes.
- **FR-010**: System MUST display an appropriate message when no processes are available to display.

### Key Entities

- **Process Node**: Represents a single Erlang process in the tree. Key attributes: identifier (PID), registered name (optional), process type (supervisor or worker), parent process.
- **Process Status**: Detailed information about a process. Key attributes: current state, current function, memory usage, message queue length, linked processes, monitored processes.
- **Supervision Tree**: The hierarchical relationship between supervisors and their child processes. Defines parent-child relationships.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can navigate to the Process Map page and view the supervision tree within 2 seconds of page load.
- **SC-002**: Users can click on any visible process node and view its status within 1 second.
- **SC-003**: The process tree correctly displays 95% or more of all running processes in the system.
- **SC-004**: Process status information refreshes automatically when viewing a process that changes state.
- **SC-005**: 90% of users can successfully identify a specific process in the tree on their first attempt (usability goal).
- **SC-006**: The page remains responsive (no visible lag) with up to 200 processes displayed simultaneously.

## Assumptions

- The web console already has a sidebar with a "System" section containing other menu items (Settings, Logs, Diagnostics).
- All authenticated console users can view the Process Map and process details without additional role-based permissions; no sensitive user data is exposed through process information.
- Standard OTP supervision tree introspection functions are available (`:supervisor.which_children/1`, `:erlang.process_info/2`, etc.).
- The tree visualization will be rendered using web technologies compatible with the existing Phoenix LiveView stack.
- Process information is read-only - users cannot kill or restart processes from this interface (that would require separate feature specification).

## Out of Scope

- Killing or restarting processes from the Process Map interface.
- Historical process data or timeline views.
- Process tracing or debugging capabilities.
- Exporting process tree data to external formats.
- Filtering or searching for specific processes by name.
- Custom process grouping or tagging.
