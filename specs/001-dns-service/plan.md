# Implementation Plan: DNS Service Implementation Fix and Dashboard Service Controls

**Branch**: `001-dns-service` | **Date**: 2025-12-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-dns-service/spec.md`

## Summary

Fix the DNS service architecture to follow the same OTP supervision patterns as working services (mDNS, DHCPv4) and add start/stop controls to the dashboard for all services. The DNS service currently fails to start due to architectural issues: supervisor returns `:ignore` when disabled (should be handled at application level), handler spawns child processes inline (should be in supervisor tree), and child process management is inconsistent with other services.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27-28
**Primary Dependencies**: Abyss (UDP server), ex_dns (DNS protocol), Phoenix LiveView 1.0, DaisyUI 5.0
**Storage**: ETS tables for caching, Agent for configuration
**Testing**: ExUnit with `mix test`, tags: `:privileged_port`, `:integration`
**Target Platform**: Linux server, Docker containers
**Project Type**: Umbrella Elixir application with 10 apps
**Performance Goals**: 100 concurrent DNS queries, 5s dashboard response time
**Constraints**: Privileged port 53 requires elevated privileges (test uses non-privileged ports)
**Scale/Scope**: 4 protocol services (DNS, mDNS, DHCPv4, DHCPv6), 1 web console

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| Module Naming Convention | ✅ PASS | All DNS modules use `YellowDog.Dns.*` pattern |
| UDP Transport via Abyss | ✅ PASS | DNS Server uses Abyss.Server already |
| Protocol Implementation Standards | ✅ PASS | Uses ex_dns for DNS protocol |
| Conditional Service Starting | ⚠️ VIOLATION | DNS supervisor incorrectly returns `:ignore` instead of letting application layer filter |
| Centralized Configuration | ✅ PASS | Uses YellowDog.Config |
| Supervisor Pattern | ⚠️ VIOLATION | DNS handler spawns ViewManager/ConfigWatcher inline instead of in supervisor tree |
| Phoenix LiveView Architecture | ✅ PASS | Dashboard uses Phoenix 1.8 patterns with DaisyUI |
| Code Quality Standards | ✅ PASS | Must compile with --warnings-as-errors |
| Telemetry Standards | ✅ PASS | DNS service emits telemetry events |
| Infrastructure Library Test Coverage | ✅ PASS | ex_dns tests pass |

**Violations to Address:**
1. Remove `:ignore` check from DNS supervisor (FR-008)
2. Move ViewManager and ConfigWatcher to supervisor tree (FR-006, FR-009)

## Project Structure

### Documentation (this feature)

```text
specs/001-dns-service/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/
├── yellow_dog/                          # Core application
│   └── lib/yellow_dog/
│       ├── application.ex               # Service orchestration (existing)
│       ├── service_manager.ex           # Service control API (existing)
│       └── config.ex                    # Configuration Agent (existing)
│
├── yellow_dog_dns/                      # DNS application (MODIFY)
│   └── lib/yellow_dog/dns/
│       ├── dns.ex                       # Public API (existing)
│       ├── supervisor.ex                # FIX: Remove :ignore logic
│       ├── server.ex                    # UDP server (existing)
│       ├── handler/
│       │   └── udp.ex                   # FIX: Remove inline process creation
│       └── view/
│           ├── manager.ex               # ViewManager (existing)
│           └── config_watcher.ex        # ConfigWatcher (existing)
│
├── yellow_dog_console/                  # Web console (MODIFY)
│   └── lib/yellow_dog/console/
│       └── live/
│           ├── dashboard_live.ex        # ADD: Event handlers
│           └── dashboard_live.html.heex # ADD: Start/Stop buttons
│
├── yellow_dog_mdns/                     # Reference implementation
├── yellow_dog_dhcpv4/                   # Reference implementation
└── yellow_dog_dhcpv6/                   # Reference implementation
```

**Structure Decision**: Umbrella Elixir project with existing directory structure. Changes are modifications to existing files, not new directory creation.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| DNS supervisor `:ignore` removal | Follow application-layer filtering pattern | Direct removal aligns with working services (mDNS, DHCPv4) |
| ViewManager in supervisor tree | Proper OTP supervision with crash recovery | Inline creation lacks crash recovery and violates OTP patterns |

## Critical Findings from Research

### DNS Service Architecture Issues

1. **Supervisor Returns `:ignore`** (`supervisor.ex:28-41`)
   - Current: Returns `:ignore` when `service_enabled?(:dns)` is false
   - Should be: Application layer filters which supervisors to start
   - Fix: Remove conditional check, always start if invoked

2. **Handler Creates Inline Processes** (`handler/udp.ex:67, 1142`)
   - Current: Handler.init() calls ViewManager.start_link() inline
   - Should be: ViewManager added to supervisor's build_children()
   - Fix: Move process creation to supervisor, handler receives registry name

3. **Missing Supervisor Children** (`supervisor.ex:51-101`)
   - Current: Zone.Manager, Cache.Manager, Server in tree
   - Missing: View.Manager, ConfigWatcher
   - Fix: Add View.Manager and ConfigWatcher to build_children()

### Dashboard Service Controls Implementation

1. **Backend API Already Exists**
   - `YellowDog.start_service/1` delegated to ServiceManager
   - `YellowDog.stop_service/1` delegated to ServiceManager
   - `YellowDog.get_all_status/1` returns all service statuses

2. **Dashboard Changes Needed**
   - Add `handle_event("start_service", ...)` to dashboard_live.ex
   - Add `handle_event("stop_service", ...)` to dashboard_live.ex
   - Add Start/Stop buttons in `:actions` slot of service cards

3. **Component Patterns Available**
   - `<.status_indicator status="running|stopped" pulse />`
   - `btn btn-success` for Start, `btn btn-error` for Stop
   - Flash messages via `put_flash/3`

## Files to Modify

| File | Change Type | Description |
|------|-------------|-------------|
| `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex` | Modify | Remove `:ignore` check, add ViewManager/ConfigWatcher to children |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex` | Modify | Remove inline ViewManager.start_link(), get from registry |
| `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex` | Modify | Add start/stop event handlers |
| `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex` | Modify | Add Start/Stop buttons to service cards |

## Implementation Order

1. **Phase 1: Fix DNS Supervisor** (FR-006, FR-007, FR-008, FR-009, FR-010)
   - Remove `:ignore` logic from start_link
   - Add View.Manager to supervisor children
   - Add ConfigWatcher to supervisor children
   - Ensure proper child ordering (dependencies first)

2. **Phase 2: Fix DNS Handler** (FR-006, FR-009)
   - Remove inline ViewManager.start_link()
   - Remove inline ConfigWatcher.start_link()
   - Get ViewManager via named process or registry
   - Update state initialization

3. **Phase 3: Dashboard Service Controls** (FR-001, FR-002, FR-003, FR-004, FR-005)
   - Add handle_event for start_service
   - Add handle_event for stop_service
   - Add Start/Stop buttons to template
   - Add flash message feedback

4. **Phase 4: Testing & Validation** (SC-001 through SC-006)
   - Test DNS service starts successfully
   - Test dashboard controls work
   - Test service status updates reflect in UI
   - Test DNS handles concurrent queries
