# Feature Specification: Complete Logger to Telemetry Migration

**Feature Branch**: `001-complete-logger-telemetry-migration`
**Created**: 2025-12-23
**Status**: Draft
**Input**: User description: "search 'ag Logger apps/*/lib', there still some Logger need to update use telemetry"

## Overview

Complete the migration of all remaining `Logger` calls to `:telemetry.execute/3` across all Yellow Dog umbrella applications. The previous telemetry-logging spec (001-telemetry-logging) migrated the protocol handlers, but 156 Logger calls remain across 20 files in 6 applications.

### Current State Analysis

**Remaining Logger calls by application:**
- `yellow_dog_dns`: 65 calls (query resolver, cache, forwarder, recursive, root zone)
- `yellow_dog_telemetry`: 48 calls (logger_handlers.ex - intentional, application.ex)
- `yellow_dog`: 24 calls (application.ex, config.ex, service_manager.ex)
- `yellow_dog_console`: 12 calls (dashboard_live.ex, settings_live.ex, service_manager.ex)
- `abyss`: 6 calls (logger.ex - intentional, rate_limiter.ex)
- `ex_dns`: 1 call (error.ex)

**Files with `require Logger`:** 27 files

## User Scenarios & Testing *(mandatory)*

### User Story 1 - DNS Query Resolver Telemetry (Priority: P1)

As an operator, I want DNS query resolution events to emit structured telemetry so I can monitor resolution performance and debug query issues.

**Why this priority**: DNS query resolution is the core functionality. Proper telemetry enables debugging slow queries, tracking resolution success rates, and identifying upstream server issues.

**Independent Test**: DNS queries can be monitored via telemetry events without any Logger output. Telemetry handlers can subscribe to resolution events and track metrics.

**Acceptance Scenarios**:

1. **Given** a DNS query is forwarded, **When** the resolution completes, **Then** a `[:yellow_dog, :dns, :query, :forward]` telemetry event is emitted with timing and server info
2. **Given** a recursive DNS query starts, **When** the resolution completes, **Then** a `[:yellow_dog, :dns, :query, :recursive]` event is emitted with iteration count
3. **Given** a cache lookup occurs, **When** the result is found/missed, **Then** a `[:yellow_dog, :dns, :cache, :lookup]` event is emitted with hit/miss status

---

### User Story 2 - Root Zone Management Telemetry (Priority: P1)

As an operator, I want root zone fetch and update events to emit telemetry so I can monitor root zone health and freshness.

**Why this priority**: Root zone is critical for recursive resolution. Telemetry enables monitoring fetch success rates and detecting stale root hints.

**Independent Test**: Root zone operations emit telemetry events that can be monitored for fetch timing and success status.

**Acceptance Scenarios**:

1. **Given** a root zone fetch is triggered, **When** the fetch completes, **Then** a `[:yellow_dog, :dns, :root_zone, :fetch]` event is emitted with timing and success status
2. **Given** root zone update occurs, **When** zones are loaded, **Then** a `[:yellow_dog, :dns, :root_zone, :update]` event is emitted with zone count

---

### User Story 3 - Core Application Lifecycle Telemetry (Priority: P2)

As an operator, I want application startup and service orchestration events to emit telemetry so I can monitor system health and debug startup issues.

**Why this priority**: Core application lifecycle events are important for debugging but less critical than query resolution.

**Independent Test**: Application start/stop and service enable/disable events emit telemetry.

**Acceptance Scenarios**:

1. **Given** YellowDog application starts, **When** initialization completes, **Then** `[:yellow_dog, :application, :start]` event is emitted
2. **Given** a service is enabled/disabled, **When** state changes, **Then** `[:yellow_dog, :service, :state_change]` event is emitted
3. **Given** configuration is loaded, **When** loading completes, **Then** `[:yellow_dog, :config, :loaded]` event is emitted

---

### User Story 4 - Web Console Telemetry (Priority: P3)

As an operator, I want web console operations to emit telemetry so I can monitor user interactions and debug UI issues.

**Why this priority**: Web console is user-facing but not core functionality. Telemetry aids debugging but is lower priority.

**Independent Test**: Console operations emit telemetry events for user actions.

**Acceptance Scenarios**:

1. **Given** dashboard loads, **When** service status is fetched, **Then** `[:yellow_dog, :console, :dashboard, :load]` event is emitted
2. **Given** settings are updated, **When** save completes, **Then** `[:yellow_dog, :console, :settings, :update]` event is emitted

---

### User Story 5 - Infrastructure Library Telemetry (Priority: P3)

As an operator, I want infrastructure library events (abyss rate limiter, ex_dns errors) to emit telemetry.

**Why this priority**: Infrastructure libraries are lower-level. Some Logger calls (in abyss/logger.ex, yellow_dog_telemetry/logger_handlers.ex) are intentional and should remain.

**Independent Test**: Rate limiter and DNS error events emit telemetry.

**Acceptance Scenarios**:

1. **Given** rate limiter is triggered, **When** limit is exceeded, **Then** `[:abyss, :rate_limiter, :exceeded]` event is emitted (already exists)
2. **Given** a DNS protocol error occurs, **When** error is raised, **Then** `[:ex_dns, :error]` event is emitted

---

### Edge Cases

- What happens when telemetry handler raises an exception? (Should not crash the process)
- How to handle Logger calls that provide user-visible output? (Keep those, document which)
- What about debug-level Logger calls during development? (Convert to telemetry with debug metadata)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST migrate all operational Logger calls to telemetry events
- **FR-002**: System MUST preserve existing Logger calls in `Abyss.Logger` module (intentional logging API)
- **FR-003**: System MUST preserve existing Logger calls in `YellowDog.Telemetry.LoggerHandlers` (telemetry-to-logger bridge)
- **FR-004**: All telemetry events MUST follow the naming convention `[:app_name, :component, :action]`
- **FR-005**: All telemetry events MUST include timing measurements where applicable
- **FR-006**: All telemetry events MUST include relevant metadata (source module, operation details)
- **FR-007**: System MUST remove `require Logger` statements from migrated files
- **FR-008**: Tests MUST NOT use `capture_log` assertions (already established in previous PR)

### Exclusions (Logger calls to KEEP)

- `apps/abyss/lib/abyss/logger.ex` - Intentional logging API module
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex` - Telemetry-to-Logger bridge

### Key Entities

- **TelemetryEvent**: Event name (list of atoms), measurements (map), metadata (map)
- **TelemetryHandler**: Handler function that processes events (in logger_handlers.ex)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All operational Logger calls migrated (target: 0 Logger calls outside exclusion list)
- **SC-002**: All tests pass without capture_log assertions
- **SC-003**: Code compiles without warnings about unused Logger
- **SC-004**: All migrated files have `require Logger` removed
- **SC-005**: Telemetry events can be subscribed to and processed by custom handlers

## Implementation Scope

### Files to Migrate

**yellow_dog_dns (65 calls, 10 files):**
- `lib/yellow_dog/dns/query/cache/cleaner.ex`
- `lib/yellow_dog/dns/query/cache/manager.ex`
- `lib/yellow_dog/dns/query/forwarder.ex`
- `lib/yellow_dog/dns/query/iterator.ex`
- `lib/yellow_dog/dns/query/recursive.ex`
- `lib/yellow_dog/dns/query/referral.ex`
- `lib/yellow_dog/dns/query/resolver.ex`
- `lib/yellow_dog/dns/root_zone/fetcher.ex`
- `lib/yellow_dog/dns/root_zone/manager.ex`

**yellow_dog (24 calls, 3 files):**
- `lib/yellow_dog/application.ex`
- `lib/yellow_dog/config.ex`
- `lib/yellow_dog/service_manager.ex`

**yellow_dog_console (12 calls, 3 files):**
- `lib/yellow_dog/console/live/dashboard_live.ex`
- `lib/yellow_dog/console/live/settings_live.ex`
- `lib/yellow_dog/console/service_manager.ex`

**abyss (partial - keep logger.ex, migrate 1 file):**
- `lib/abyss/rate_limiter.ex` - migrate

**ex_dns (1 call, 1 file):**
- `lib/dns/error.ex`

### Files to Keep (Intentional Logger usage)
- `apps/abyss/lib/abyss/logger.ex` - Logging API
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex` - Telemetry bridge
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/application.ex` - Startup logging OK
