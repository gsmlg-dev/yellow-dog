# Implementation Plan: Telemetry-Based Logging System

**Branch**: `001-telemetry-logging` | **Date**: 2025-12-22 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-telemetry-logging/spec.md`

## Summary

Migrate all application logging from direct `Logger` module calls to a centralized telemetry-based logging system using `yellow_dog_telemetry`. The core `YellowDog.Telemetry` module already provides logging functions (`info/2`, `debug/2`, etc.) that emit telemetry events. This implementation adds logger handler functions for protocol-specific events (DNS, DHCP, mDNS), integrates handler attachment into application startup, and migrates all existing direct Logger calls to use the telemetry-based approach.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27-28
**Primary Dependencies**: `:telemetry` (already present), `yellow_dog_telemetry` (in umbrella)
**Storage**: N/A (in-memory telemetry events)
**Testing**: ExUnit with telemetry handler attachment for verification
**Target Platform**: Linux server (DNS/DHCP services)
**Project Type**: Umbrella application
**Performance Goals**: Zero additional overhead (telemetry is designed for minimal impact)
**Constraints**: Must maintain 100% log parity with existing output
**Scale/Scope**: ~46 files with direct Logger calls to migrate

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Gate | Status | Notes |
|------|--------|-------|
| Module naming follows `YellowDog.<AppName>.*` | ✅ Pass | All new code in `YellowDog.Telemetry` namespace |
| UDP servers use Abyss library | ✅ N/A | No transport changes |
| TCP servers use :thousand_island | ✅ N/A | No transport changes |
| HTTP requests use :http_fetch | ✅ N/A | No HTTP changes |
| Code compiles with --warnings-as-errors | ✅ Verify | Will verify during implementation |
| No direct Logger calls in protocol apps | ⚠️ Violation | Current state violates; this feature fixes it |
| All apps use yellow_dog_telemetry | ✅ Pass | Already configured as dependency |
| Event naming: `[:yellow_dog, <service>, <resource>, <action>]` | ✅ Pass | Will follow convention |

**Gate Status**: ✅ PASS (one violation is the purpose of this feature)

## Project Structure

### Documentation (this feature)

```text
specs/001-telemetry-logging/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (telemetry event contracts)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
# Umbrella structure - affected applications
apps/yellow_dog_telemetry/lib/yellow_dog/
├── telemetry.ex                     # Add attach_logger_handlers/0, detach_logger_handlers/0
└── telemetry/
    ├── application.ex               # No changes (existing log handlers)
    └── logger_handlers.ex           # NEW: Protocol-specific logger handlers

apps/yellow_dog/lib/yellow_dog/
└── application.ex                   # Add call to attach_logger_handlers/0 at startup

# Protocol apps to migrate (remove direct Logger calls)
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── handler/udp.ex                   # Migrate to telemetry events
├── zone/*.ex                        # Migrate to telemetry events
├── query/*.ex                       # Migrate to telemetry events
└── ...

apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/
├── handler.ex                       # Migrate to telemetry events
├── lease_manager.ex                 # Migrate to telemetry events
└── ...

apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/
├── handler.ex                       # Migrate to telemetry events
├── lease_manager.ex                 # Migrate to telemetry events
└── ...

apps/yellow_dog_mdns/lib/yellow_dog/mdns/
├── handler.ex                       # Migrate to telemetry events
├── service_registry.ex              # Migrate to telemetry events
├── responder.ex                     # Migrate to telemetry events
└── ...

# Test files
apps/yellow_dog_telemetry/test/yellow_dog/
└── logger_handlers_test.exs         # NEW: Tests for handler attachment/detachment
```

**Structure Decision**: Umbrella project structure is preserved. New code added to `yellow_dog_telemetry`, migrations occur in each protocol app.

## Complexity Tracking

No violations requiring justification. The feature aligns with constitution requirements.

## Implementation Approach

### Phase 1: Core Infrastructure (P1)

1. **Add `attach_logger_handlers/0` to `YellowDog.Telemetry`**
   - Attaches handlers for all protocol-specific telemetry events
   - Follows naming: `[:yellow_dog, :dns, :query, *]`, `[:yellow_dog, :dhcpv4, :lease, *]`, etc.
   - Uses lazy message formatting (`fn -> message end`)

2. **Add `detach_logger_handlers/0` to `YellowDog.Telemetry`**
   - Enables clean handler removal for testing
   - Detaches all handlers attached by `attach_logger_handlers/0`

3. **Create `YellowDog.Telemetry.LoggerHandlers` module**
   - Handler functions for each event type
   - Consistent log formatting
   - Error-safe (handlers must not crash)

4. **Update `YellowDog.Application.start/2`**
   - Call `YellowDog.Telemetry.attach_logger_handlers/0` before starting services

### Phase 2: Protocol Event Emission (P1)

5. **DNS telemetry events**
   - `[:yellow_dog, :dns, :query, :received]` - query received
   - `[:yellow_dog, :dns, :query, :completed]` - query processed
   - `[:yellow_dog, :dns, :query, :error]` - query error
   - `[:yellow_dog, :dns, :cache, :hit]` - cache hit
   - `[:yellow_dog, :dns, :cache, :miss]` - cache miss
   - `[:yellow_dog, :dns, :zone, :loaded]` - zone loaded

6. **DHCPv4 telemetry events**
   - `[:yellow_dog, :dhcpv4, :lease, :requested]` - DISCOVER/REQUEST received
   - `[:yellow_dog, :dhcpv4, :lease, :granted]` - lease allocated
   - `[:yellow_dog, :dhcpv4, :lease, :released]` - lease released
   - `[:yellow_dog, :dhcpv4, :lease, :expired]` - lease expired
   - `[:yellow_dog, :dhcpv4, :server, :started]` - server started

7. **DHCPv6 telemetry events**
   - `[:yellow_dog, :dhcpv6, :lease, :requested]` - SOLICIT/REQUEST received
   - `[:yellow_dog, :dhcpv6, :lease, :granted]` - lease allocated
   - `[:yellow_dog, :dhcpv6, :lease, :released]` - lease released
   - `[:yellow_dog, :dhcpv6, :lease, :expired]` - lease expired
   - `[:yellow_dog, :dhcpv6, :server, :started]` - server started

8. **mDNS telemetry events**
   - `[:yellow_dog, :mdns, :service, :registered]` - service registered
   - `[:yellow_dog, :mdns, :service, :unregistered]` - service removed
   - `[:yellow_dog, :mdns, :query, :received]` - query received
   - `[:yellow_dog, :mdns, :response, :sent]` - response sent
   - `[:yellow_dog, :mdns, :server, :started]` - server started

### Phase 3: Migration (P2)

9. **Migrate existing Logger calls**
   - Replace `Logger.info/debug/warn/error` with `:telemetry.execute/3`
   - Or use existing `YellowDog.Telemetry.info/2` etc.
   - Verify log parity (same messages produced)

10. **Update tests**
    - Add telemetry handler tests
    - Verify event emission in protocol tests
    - Test handler attachment/detachment

### Files Affected

**46 files with direct Logger calls** (from grep analysis):
- Core apps: `yellow_dog/application.ex`, `yellow_dog/config.ex`, `yellow_dog/service_manager.ex`
- DNS: 14 files in `yellow_dog_dns/`
- DHCPv4: 7 files in `yellow_dog_dhcpv4/`
- DHCPv6: 6 files in `yellow_dog_dhcpv6/`
- mDNS: 10 files in `yellow_dog_mdns/`
- Console: 4 files in `yellow_dog_console/`
- Infrastructure: `abyss/rate_limiter.ex`, `abyss/logger.ex`, `ex_dns/error.ex`

**Note**: Infrastructure libraries (abyss, ex_dns) are **out of scope** per spec.
