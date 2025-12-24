# Research: Complete Logger to Telemetry Migration

**Date**: 2025-12-23
**Feature**: Complete Logger to Telemetry Migration
**Status**: Complete

## Research Summary

This migration follows established patterns from Constitution v1.3.0 and the previous 001-telemetry-logging implementation. No unknowns require clarification.

## Decision 1: Telemetry Event Pattern

**Decision**: Use `:telemetry.execute/3` with 4-part event names

**Rationale**:
- Constitution v1.3.0 mandates this pattern
- Already implemented in protocol handlers (DHCP, mDNS, DNS handlers)
- Consistent with existing `YellowDog.Telemetry.LoggerHandlers` infrastructure

**Alternatives Considered**:
- Direct Logger calls (rejected - prohibited by constitution)
- Custom logging wrapper (rejected - adds complexity, telemetry already works)
- Structured logging library (rejected - telemetry is Elixir standard)

**Pattern**:
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :complete],
  %{duration_ms: duration, count: 1},
  %{query: query, result: result, source: __MODULE__}
)
```

## Decision 2: Logger Handler Location

**Decision**: Keep all Logger handlers in `YellowDog.Telemetry.LoggerHandlers`

**Rationale**:
- Centralized handler management
- Already exists and handles protocol events
- Allows enable/disable of logging without code changes
- Constitution mandates centralized telemetry through `yellow_dog_telemetry`

**Alternatives Considered**:
- Inline Logger calls with telemetry (rejected - violates constitution)
- Separate handler files per app (rejected - fragmented, harder to manage)

## Decision 3: Event Naming Convention

**Decision**: Follow `[:app_name, :component, :resource, :action]` pattern

**Rationale**:
- Constitution v1.3.0 specifies this pattern
- Consistent with existing events
- Enables hierarchical event subscription

**Event Categories**:

| App | Component | Resource | Actions |
|-----|-----------|----------|---------|
| yellow_dog | dns | query | start, complete, error, forward, recursive |
| yellow_dog | dns | cache | hit, miss, store, cleanup |
| yellow_dog | dns | root_zone | fetch, update, error |
| yellow_dog | application | lifecycle | start, stop |
| yellow_dog | config | loading | loaded, error |
| yellow_dog | service | state | start, stop, error |
| yellow_dog | console | dashboard | load, error |
| yellow_dog | console | settings | update, error |
| abyss | rate_limiter | check | allowed, exceeded |
| ex_dns | error | parse | raised |

## Decision 4: Measurement Fields

**Decision**: Include timing, counts, and status in measurements

**Rationale**:
- Enables metrics collection (Prometheus, StatsD)
- Standard telemetry practice
- Lightweight (just maps)

**Standard Measurements**:
```elixir
# Duration-based events
%{duration_ms: 123, count: 1}

# Count-only events
%{count: 1}

# Status events
%{count: 1, success: true}

# Error events
%{count: 1, error_count: 1}
```

## Decision 5: Metadata Fields

**Decision**: Include source module, operation details, and context

**Rationale**:
- Enables debugging and tracing
- Logger handlers can format appropriately
- Consistent with existing handler patterns

**Standard Metadata**:
```elixir
%{
  source: __MODULE__,
  query: query,
  result: result,
  timestamp: System.system_time(:millisecond)
}
```

## Decision 6: Exclusion List

**Decision**: Exclude intentional Logger usage files from migration

**Files Excluded**:
- `apps/abyss/lib/abyss/logger.ex` - Logging API module
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex` - Telemetry-to-Logger bridge
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/application.ex` - Bootstrap logging

**Rationale**:
- These files are part of the logging infrastructure
- They bridge telemetry events to Logger output
- Constitution allows Logger in telemetry bridge modules

## Decision 7: Test Strategy

**Decision**: Remove all capture_log assertions, test telemetry events directly

**Rationale**:
- Already established in previous PR (#13)
- Telemetry events can be captured with `:telemetry.attach/4`
- More reliable than log output matching

**Test Pattern**:
```elixir
test "emits telemetry on query completion" do
  ref = make_ref()

  :telemetry.attach(
    "test-handler-#{inspect(ref)}",
    [:yellow_dog, :dns, :query, :complete],
    fn _event, measurements, metadata, pid ->
      send(pid, {:telemetry, measurements, metadata})
    end,
    self()
  )

  # Trigger the operation
  perform_query()

  # Assert telemetry was emitted
  assert_receive {:telemetry, %{duration_ms: _}, %{query: _}}

  :telemetry.detach("test-handler-#{inspect(ref)}")
end
```

## Decision 8: Migration Order

**Decision**: Migrate by application in priority order (P1 → P3)

**Order**:
1. **P1**: `yellow_dog_dns` (65 calls) - Core functionality
2. **P1**: Root zone modules in `yellow_dog_dns` - Critical for resolution
3. **P2**: `yellow_dog` (24 calls) - Application lifecycle
4. **P3**: `yellow_dog_console` (12 calls) - UI operations
5. **P3**: `abyss`, `ex_dns` (7 calls) - Infrastructure

**Rationale**:
- DNS query resolution is the most critical path
- Each phase can be tested independently
- Lower priority items can be deferred if needed

## Open Questions (Resolved)

All questions resolved. No NEEDS CLARIFICATION items remain.

## References

- Constitution v1.3.0: `.specify/memory/constitution.md`
- Existing telemetry handlers: `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex`
- Previous migration PR: #13 (protocol handlers)
