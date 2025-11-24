# Feature Specification: Console Settings Management

**Feature Branch**: `001-console-settings`
**Created**: 2025-11-10
**Status**: Draft
**Input**: User description: "In the yellow dog console app, please create /settings router and manage the config file content. We need 4 tab for dns, mdns, dhcpv4 and dhcpv6."

## Clarifications

### Session 2025-11-10

- Q: When an administrator changes service configuration and saves it, when should the change take effect? → A: Staged - Configuration saved but marked "pending", administrator explicitly applies changes
- Q: How should the system handle when two administrators edit the same service configuration simultaneously? → A: Optimistic locking - Second save fails with error if configuration was modified since page load
- Q: Can administrators add, delete, or rename DHCP address pools through the settings interface, or only edit existing pools? → A: Full CRUD - Administrators can create new pools, edit existing pools, and delete pools
- Q: When the configuration file is missing or corrupted when the settings page is accessed, how should the system behave? → A: Display error with recovery options - Show error and offer: use defaults, restore from backup, or create new
- Q: When an administrator clicks "Apply Changes" after saving configuration modifications, what scope should the apply action cover? → A: Per-service apply - Each service tab has its own "Apply Changes" button affecting only that service

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View and Edit DNS Configuration (Priority: P1)

An administrator needs to view and modify DNS service configuration settings such as listen address, port, and service enablement through the web console interface.

**Why this priority**: DNS is a core service and administrators must be able to configure it without directly editing configuration files. This is the most fundamental configuration need.

**Independent Test**: Can be fully tested by navigating to settings page, viewing DNS configuration, modifying port value from 53 to 5353, saving, and verifying the configuration file reflects the change. Delivers immediate value by enabling DNS configuration management.

**Acceptance Scenarios**:

1. **Given** administrator is on the dashboard, **When** they navigate to /settings, **Then** they see a settings page with 4 tabs: DNS, mDNS, DHCPv4, DHCPv6
2. **Given** administrator is on settings page, **When** they click the DNS tab, **Then** they see current DNS configuration including: service enabled/disabled toggle, listen address, port number
3. **Given** administrator views DNS settings, **When** they modify the port from 53 to 5353 and click Save, **Then** the configuration is saved successfully, marked as "pending", and a success message is displayed
4. **Given** administrator has saved DNS settings with pending changes, **When** they click the "Apply Changes" button on the DNS tab, **Then** the pending DNS configuration is activated and only the DNS service is restarted with new settings
5. **Given** administrator has modified DNS settings, **When** they refresh the page, **Then** the saved values persist and pending status indicator is displayed on the DNS tab

---

### User Story 2 - View and Edit mDNS Configuration (Priority: P2)

An administrator needs to view and modify mDNS service configuration settings including service enablement, listen address, port, and service discovery mode through the web console.

**Why this priority**: mDNS configuration is simpler than DNS but still essential for service discovery functionality. Administrators need to enable/disable and configure mDNS without file editing.

**Independent Test**: Can be tested by accessing settings page, switching to mDNS tab, toggling service enabled status, changing port value, saving configuration, and verifying changes persist. Provides standalone value for mDNS management.

**Acceptance Scenarios**:

1. **Given** administrator is on settings page, **When** they click the mDNS tab, **Then** they see current mDNS configuration including: service enabled/disabled toggle, listen address, port number, mode selection (responder/hybrid)
2. **Given** administrator views mDNS settings, **When** they toggle service enabled from true to false and click Save, **Then** the configuration is saved and mDNS service state is updated
3. **Given** administrator modifies mDNS settings, **When** they navigate away and return to mDNS tab, **Then** all saved changes are displayed correctly

---

### User Story 3 - View and Edit DHCPv4 Configuration (Priority: P2)

An administrator needs to view and modify DHCPv4 service configuration settings including service enablement, listen address, port, and pool configuration through the web console. Administrators can create new address pools, edit existing pools, and delete pools.

**Why this priority**: DHCPv4 is critical for IPv4 address management. Configuration includes more complex settings like address pools, lease times, and gateway addresses that benefit from a structured interface. Full pool management capabilities enable administrators to adapt to changing network requirements.

**Independent Test**: Can be tested by accessing settings page, selecting DHCPv4 tab, creating a new pool with defined range, modifying pool settings (range, lease time, gateway), deleting an unused pool, saving configuration, and verifying all changes are reflected in the configuration file. Provides independent value for DHCPv4 management.

**Acceptance Scenarios**:

1. **Given** administrator is on settings page, **When** they click the DHCPv4 tab, **Then** they see current DHCPv4 configuration including: service enabled/disabled toggle, listen address, port number, configured address pools, and "Add Pool" button
2. **Given** administrator views DHCPv4 settings, **When** they click "Add Pool", **Then** they see a form to create new pool with fields: pool name, address range (start/end), lease time, gateway, DNS servers
3. **Given** administrator creates new pool, **When** they fill in required fields and click Save, **Then** the new pool is added to configuration and marked as pending
4. **Given** administrator views existing pool configuration, **When** they view a pool, **Then** they see pool name, address range (start/end), lease time, gateway, DNS servers, and "Delete Pool" button
5. **Given** administrator modifies pool settings, **When** they change lease time from 3600 to 7200 seconds and click Save, **Then** the configuration is saved successfully and marked as pending
6. **Given** administrator wants to remove a pool, **When** they click "Delete Pool" and confirm deletion, **Then** the pool is removed from configuration and marked as pending deletion
7. **Given** administrator modifies DHCPv4 configuration, **When** they save changes, **Then** the TOML configuration file is updated with the new values

---

### User Story 4 - View and Edit DHCPv6 Configuration (Priority: P3)

An administrator needs to view and modify DHCPv6 service configuration settings including service enablement, listen address, port, and IPv6 address pool configuration through the web console. Administrators can create new IPv6 address pools, edit existing pools, and delete pools.

**Why this priority**: DHCPv6 configuration is similar to DHCPv4 but for IPv6 networks. While important, IPv6 adoption is less critical than IPv4 for most deployments, making this lower priority. Full pool management capabilities enable future-proofing for IPv6 network expansion.

**Independent Test**: Can be tested independently by accessing settings page, selecting DHCPv6 tab, creating a new IPv6 pool, modifying IPv6 pool settings (IPv6 range, preferred/valid lifetimes), deleting an unused pool, saving, and verifying all configuration file updates. Provides complete DHCPv6 management capability.

**Acceptance Scenarios**:

1. **Given** administrator is on settings page, **When** they click the DHCPv6 tab, **Then** they see current DHCPv6 configuration including: service enabled/disabled toggle, listen address (IPv6), port number, configured IPv6 address pools, and "Add Pool" button
2. **Given** administrator views DHCPv6 settings, **When** they click "Add Pool", **Then** they see a form to create new IPv6 pool with fields: pool name, IPv6 address range, preferred lifetime, valid lifetime, DNS servers
3. **Given** administrator creates new IPv6 pool, **When** they fill in required fields and click Save, **Then** the new pool is added to configuration and marked as pending
4. **Given** administrator views existing pool configuration, **When** they view a pool, **Then** they see pool name, IPv6 address range, preferred lifetime, valid lifetime, DNS servers, and "Delete Pool" button
5. **Given** administrator modifies DHCPv6 settings, **When** they change preferred lifetime and click Save, **Then** the configuration is saved and marked as pending
6. **Given** administrator wants to remove an IPv6 pool, **When** they click "Delete Pool" and confirm deletion, **Then** the pool is removed from configuration and marked as pending deletion

---

### User Story 5 - Configuration Validation and Error Handling (Priority: P1)

An administrator needs immediate feedback when entering invalid configuration values, preventing configuration errors that could break service functionality.

**Why this priority**: Validation is critical to prevent administrators from saving invalid configurations that could cause service failures. This is a cross-cutting concern affecting all tabs.

**Independent Test**: Can be tested by attempting to enter invalid values (invalid IP address, port out of range, invalid IPv6 address) in any tab, attempting to save, and verifying validation errors are displayed without saving. Prevents configuration corruption independently.

**Acceptance Scenarios**:

1. **Given** administrator is editing DNS settings, **When** they enter port value "99999" (invalid range), **Then** a validation error message is displayed indicating valid port range (1-65535)
2. **Given** administrator is editing any service settings, **When** they enter an invalid IP address format like "256.1.1.1", **Then** a validation error is displayed and save button is disabled
3. **Given** administrator has validation errors, **When** they correct all errors, **Then** the save button becomes enabled and they can save successfully
4. **Given** administrator attempts to save configuration, **When** the save operation fails due to file permissions or other errors, **Then** an error message is displayed with details
5. **Given** two administrators are editing same service configuration, **When** first administrator saves changes and second administrator attempts to save, **Then** second save is rejected with conflict error message and option to reload current configuration
6. **Given** administrator navigates to settings page, **When** configuration file is missing or corrupted, **Then** error message is displayed with three recovery options: "Use Default Configuration", "Restore from Backup", "Create New Configuration"
7. **Given** administrator sees configuration recovery options, **When** they select "Use Default Configuration", **Then** system loads built-in defaults and allows editing
8. **Given** administrator sees configuration recovery options and backup exists, **When** they select "Restore from Backup", **Then** system loads most recent backup and allows editing
9. **Given** administrator sees configuration recovery options, **When** they select "Create New Configuration", **Then** system initializes minimal valid configuration and allows editing

---

### Edge Cases

- What happens when administrator selects "Restore from Backup" but no backup file exists?
- What happens when administrator's save is rejected due to concurrent modification (optimistic lock failure) and they choose to reload?
- What happens when administrator attempts to apply pending configuration but the service fails to restart?
- How does the system handle configuration values that are technically valid but could cause service failures (e.g., port already in use)?
- What happens if the configuration file becomes read-only or has permission issues during save operation?
- How are default values displayed when a configuration key is missing from the file?
- What happens if an administrator saves new pending changes before applying existing pending changes?
- What happens if administrator reloads the page while having unsaved edits in the form?
- What happens when administrator attempts to create a pool with IP range that overlaps an existing pool?
- What happens when administrator tries to delete a pool that has active leases assigned?
- What happens when administrator creates multiple pools but only applies changes for one service at a time?
- How does the system handle pool name conflicts when creating a new pool?
- What happens if administrator chooses "Create New Configuration" but the file path is not writable?
- What happens when administrator has pending changes for multiple services (e.g., DNS and DHCPv4) and only applies changes for one service?
- What happens if applying changes for one service fails while other services have pending changes?
- What happens when administrator switches between tabs while one service has pending changes?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a /settings route in the web console that displays a settings management page
- **FR-002**: System MUST display 4 tabs on the settings page labeled: "DNS", "mDNS", "DHCPv4", "DHCPv6"
- **FR-003**: System MUST load current configuration from the TOML configuration file when settings page is accessed
- **FR-004**: System MUST display DNS configuration fields including: enabled (boolean), listen address (string), port (integer)
- **FR-005**: System MUST display mDNS configuration fields including: enabled (boolean), listen address (string), port (integer), mode (select: responder/hybrid)
- **FR-006**: System MUST display DHCPv4 configuration fields including: enabled (boolean), listen address (string), port (integer), pool configurations (list)
- **FR-007**: System MUST display DHCPv6 configuration fields including: enabled (boolean), listen address (IPv6 string), port (integer), pool configurations (list)
- **FR-008**: System MUST allow administrators to edit configuration values in form fields
- **FR-009**: System MUST validate IP address formats (IPv4 for DNS/mDNS/DHCPv4, IPv6 for DHCPv6)
- **FR-010**: System MUST validate port numbers are within valid range (1-65535)
- **FR-011**: System MUST display validation errors inline next to the relevant form field
- **FR-012**: System MUST disable the Save button when validation errors exist
- **FR-013**: System MUST save configuration changes to the TOML configuration file when Save button is clicked
- **FR-014**: System MUST preserve the structure and format of the TOML configuration file when saving
- **FR-015**: System MUST display a success message when configuration is saved successfully
- **FR-016**: System MUST display an error message when configuration save fails
- **FR-017**: System MUST reload configuration values after successful save to reflect persisted state
- **FR-018**: System MUST use YellowDog.Config module to read current configuration
- **FR-019**: System MUST persist changes to the configuration file path defined in YellowDog application
- **FR-020**: System MUST handle missing configuration keys by displaying appropriate default values
- **FR-021**: System MUST mark saved configuration changes as "pending" until administrator explicitly applies them
- **FR-022**: System MUST provide an "Apply Changes" button on each service tab (DNS, mDNS, DHCPv4, DHCPv6) that applies changes only for that specific service
- **FR-023**: System MUST display a visual indicator on each service tab when that service has pending (unapplied) changes
- **FR-024**: System MUST show both current active configuration and pending configuration values when changes exist for a service
- **FR-042**: System MUST restart only the specific service when its "Apply Changes" button is clicked, leaving other services unaffected
- **FR-043**: System MUST allow administrators to have pending changes for multiple services simultaneously, applying each independently
- **FR-025**: System MUST track configuration version or timestamp when administrator loads settings page
- **FR-026**: System MUST detect if configuration was modified by another administrator before allowing save
- **FR-027**: System MUST reject save operation with error message if configuration was modified since page load (optimistic locking)
- **FR-028**: System MUST provide option to reload current configuration and retry edit when save is rejected due to conflict
- **FR-029**: System MUST provide "Add Pool" action for DHCPv4 and DHCPv6 configuration tabs
- **FR-030**: System MUST display form for creating new address pool with required fields: pool name, address range, lease/lifetime parameters, gateway (DHCPv4), DNS servers
- **FR-031**: System MUST validate new pool configuration including: unique pool name, non-overlapping IP ranges, valid lifetime values
- **FR-032**: System MUST provide "Delete Pool" action for each configured address pool
- **FR-033**: System MUST require confirmation before deleting an address pool
- **FR-034**: System MUST prevent deletion of the last remaining pool in a service configuration
- **FR-035**: System MUST allow administrators to edit pool name, address range, and all pool parameters for existing pools
- **FR-036**: System MUST detect when configuration file is missing or corrupted on settings page load
- **FR-037**: System MUST display error message explaining the configuration file issue (missing or corrupted)
- **FR-038**: System MUST provide recovery option to "Use Default Configuration" which loads built-in defaults
- **FR-039**: System MUST provide recovery option to "Restore from Backup" which loads most recent backup file if available
- **FR-040**: System MUST provide recovery option to "Create New Configuration" which initializes minimal valid configuration
- **FR-041**: System MUST disable configuration editing until administrator selects a recovery option

### Key Entities *(include if feature involves data)*

- **Service Configuration**: Represents configuration for a single service (DNS, mDNS, DHCPv4, DHCPv6) with attributes: enabled (boolean), listen address (string), port (integer), service-specific settings (map)
- **Address Pool**: Represents an IP address pool for DHCP services with attributes: name (string), range start/end (string), lease time (integer), gateway (string), DNS servers (list of strings)
- **Configuration File**: Represents the TOML configuration file with attributes: file path (string), content (map), last modified timestamp

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Administrators can view current configuration for any service within 2 seconds of navigating to settings page
- **SC-002**: Administrators can modify and save configuration changes for any service within 1 minute
- **SC-003**: Invalid configuration values are detected and prevented from being saved 100% of the time
- **SC-004**: Configuration file remains valid TOML format after all save operations (no corruption)
- **SC-005**: Configuration changes persist across page refreshes and browser sessions
- **SC-006**: 95% of configuration save operations complete successfully within 3 seconds
- **SC-007**: Administrators receive clear feedback (success or error messages) for 100% of save operations
