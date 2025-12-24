# Implementation Plan: Real-time Logs Page

**Branch**: `001-realtime-logs-page` | **Date**: 2025-12-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-realtime-logs-page/spec.md`

## Summary

Implement a real-time logs viewing page at `/logs` in the YellowDog Console that streams telemetry log events to connected clients, allowing filtering by module (DNS, DHCPv4, DHCPv6, mDNS, Console, Core) and log level (debug, info, warning, error). The page uses Phoenix LiveView with telemetry event subscription to display logs in real-time, with pause/resume/clear controls and automatic buffer management.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27+
**Primary Dependencies**: Phoenix LiveView 1.0, DaisyUI 5.0, YellowDog.Telemetry (in_umbrella)
**Storage**: N/A (in-memory log buffer in LiveView assigns, no persistence required)
**Testing**: ExUnit with LiveView test helpers
**Target Platform**: Web browser (Phoenix LiveView via WebSocket)
**Project Type**: Umbrella application - web console module (`yellow_dog_console`)
**Performance Goals**: <100ms log delivery latency, smooth scrolling with 1000 entries
**Constraints**: Max 1000 log entries in buffer, rate limit 100 entries/second display
**Scale/Scope**: Single page with real-time streaming, 6 module filters, 4 log levels

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| Module Naming (`YellowDog.Console.*`) | ✅ PASS | Will use `YellowDog.Console.Live.LogsLive` |
| Phoenix LiveView patterns | ✅ PASS | Uses `use YellowDog.Console, :live_view` |
| DaisyUI components | ✅ PASS | Will use existing CoreComponents |
| Telemetry for logging | ✅ PASS | Subscribes to existing `[:yellow_dog, :log, *]` events |
| No direct Logger calls | ✅ PASS | Only receiving telemetry events, not emitting |
| Abyss UDP requirement | N/A | No UDP transport in this feature |
| HTTP via :http_fetch | N/A | No HTTP requests in this feature |
| Tests required | ✅ WILL COMPLY | LiveView tests will be added |
| Formatting/Credo | ✅ WILL COMPLY | Standard formatting applied |

**Gate Status**: ✅ PASSED - No violations

## Project Structure

### Documentation (this feature)

```text
specs/001-realtime-logs-page/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (N/A - no API contracts)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/yellow_dog_console/
├── lib/yellow_dog/console/
│   ├── live/
│   │   └── logs_live.ex              # Main LiveView module
│   └── components/
│       └── core_components.ex        # Existing (may add log-specific components)
├── lib/yellow_dog/console/
│   └── router.ex                     # Add /logs route (route exists but not implemented)
└── test/yellow_dog/console/live/
    └── logs_live_test.exs            # LiveView tests

apps/yellow_dog_telemetry/
└── lib/yellow_dog/telemetry/
    └── log_broadcaster.ex            # GenServer to broadcast log events to LiveViews
```

**Structure Decision**: Single LiveView module with telemetry subscription. A separate `LogBroadcaster` GenServer in `yellow_dog_telemetry` will attach to telemetry events and broadcast to subscribers via Phoenix.PubSub, following the existing pattern used by mDNS and DHCP services.

## Complexity Tracking

> No violations requiring justification. Feature uses standard patterns.

| Consideration | Decision | Rationale |
|--------------|----------|-----------|
| PubSub vs direct telemetry attach | PubSub via LogBroadcaster | Follows existing patterns (mDNS, DHCP); cleaner LiveView code; single telemetry handler |
| Filter state persistence | LiveView assigns only | User specified "realtime only" - no need for persistence |
| Log entry storage | List in assigns | Simple, sufficient for 1000 entries; FIFO eviction |

---

## Post-Design Constitution Re-Check

*Re-validated after Phase 1 design completion.*

| Principle | Status | Verification |
|-----------|--------|--------------|
| Module Naming | ✅ PASS | `YellowDog.Console.LogsLive`, `YellowDog.Telemetry.LogBroadcaster` |
| Phoenix LiveView patterns | ✅ PASS | Standard mount/handle_info/handle_event pattern |
| DaisyUI components | ✅ PASS | Using badge, btn, join classes per existing patterns |
| Telemetry integration | ✅ PASS | Subscribes to existing [:yellow_dog, :log, *] events via PubSub |
| No direct Logger calls | ✅ PASS | LogBroadcaster only receives events, doesn't emit |
| Tests | ✅ PLANNED | LiveView test in logs_live_test.exs |
| Formatting/Credo | ✅ PLANNED | Will run mix format, mix credo |

**Final Gate Status**: ✅ ALL PASSED

---

## Generated Artifacts

| Artifact | Path | Status |
|----------|------|--------|
| Implementation Plan | `specs/001-realtime-logs-page/plan.md` | ✅ Complete |
| Research | `specs/001-realtime-logs-page/research.md` | ✅ Complete |
| Data Model | `specs/001-realtime-logs-page/data-model.md` | ✅ Complete |
| Quickstart | `specs/001-realtime-logs-page/quickstart.md` | ✅ Complete |
| API Contracts | N/A | Not applicable (no external API) |
| Tasks | `specs/001-realtime-logs-page/tasks.md` | ⏳ Pending `/speckit.tasks` |

---

## Next Steps

Run `/speckit.tasks` to generate the actionable task list for implementation.
