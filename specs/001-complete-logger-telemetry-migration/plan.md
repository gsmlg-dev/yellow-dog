# Implementation Plan: Complete Logger to Telemetry Migration

**Branch**: `001-complete-logger-telemetry-migration` | **Date**: 2025-12-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-complete-logger-telemetry-migration/spec.md`

## Summary

Complete the migration of all remaining `Logger` calls to `:telemetry.execute/3` across all Yellow Dog umbrella applications. The previous telemetry-logging spec migrated protocol handlers, but 156 Logger calls remain across 20 files in 6 applications. This plan covers systematic migration following the established patterns from the constitution.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27-28
**Primary Dependencies**: `:telemetry` (~> 1.0), `yellow_dog_telemetry` (umbrella)
**Storage**: ETS tables for caching, Agent for configuration (no changes)
**Testing**: ExUnit with telemetry event assertions (no capture_log)
**Target Platform**: Linux server (DNS/DHCP services)
**Project Type**: Elixir umbrella with 10 applications
**Performance Goals**: No performance degradation from telemetry (telemetry is lightweight)
**Constraints**: Must not break existing functionality; all tests must pass
**Scale/Scope**: 156 Logger calls across 20 files in 6 applications

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Pre-Research Gates

| Principle | Status | Notes |
|-----------|--------|-------|
| Logging Standards (v1.3.0) | ✅ PASS | This spec implements the mandatory logging standard |
| Module Naming Convention | ✅ PASS | No new modules; existing naming preserved |
| Telemetry Standards | ✅ PASS | All events follow `[:app, :component, :action]` pattern |
| Transport Layer Standards | ✅ N/A | No transport changes |
| Code Quality Standards | ✅ PASS | Will compile with --warnings-as-errors |
| Testing Standards | ✅ PASS | Tests will not use capture_log assertions |

### Exclusions (Intentional Logger Usage - Constitution Compliant)

Per Constitution v1.3.0, these files are **allowed** to use Logger directly:
- `apps/abyss/lib/abyss/logger.ex` - Logging API module (provides logging interface)
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/logger_handlers.ex` - Telemetry-to-Logger bridge
- `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/application.ex` - Bootstrap logging before telemetry attached

## Project Structure

### Documentation (this feature)

```text
specs/001-complete-logger-telemetry-migration/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (telemetry event catalog)
├── quickstart.md        # Phase 1 output (migration guide)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (files to modify)

```text
apps/
├── yellow_dog_dns/lib/yellow_dog/dns/
│   ├── query/
│   │   ├── cache/cleaner.ex      # Cache cleanup telemetry
│   │   ├── cache/manager.ex      # Cache operations telemetry
│   │   ├── forwarder.ex          # Forward resolution telemetry
│   │   ├── iterator.ex           # Iteration telemetry
│   │   ├── recursive.ex          # Recursive resolution telemetry
│   │   ├── referral.ex           # Referral handling telemetry
│   │   └── resolver.ex           # Main resolver telemetry
│   └── root_zone/
│       ├── fetcher.ex            # Root zone fetch telemetry
│       └── manager.ex            # Root zone management telemetry
│
├── yellow_dog/lib/yellow_dog/
│   ├── application.ex            # App lifecycle telemetry
│   ├── config.ex                 # Config loading telemetry
│   └── service_manager.ex        # Service orchestration telemetry
│
├── yellow_dog_console/lib/yellow_dog/console/
│   ├── live/dashboard_live.ex    # Dashboard operations telemetry
│   ├── live/settings_live.ex     # Settings operations telemetry
│   └── service_manager.ex        # Console service telemetry
│
├── abyss/lib/abyss/
│   └── rate_limiter.ex           # Rate limiter telemetry (partial)
│
└── ex_dns/lib/dns/
    └── error.ex                  # DNS error telemetry
```

**Structure Decision**: Existing umbrella structure preserved. No new directories or modules created. Only modifying existing files to replace Logger calls with telemetry events.

## Complexity Tracking

> No constitution violations requiring justification.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| N/A | N/A | N/A |

## Migration Strategy

### Phase 1: DNS Query System (65 calls, P1)

Files in `apps/yellow_dog_dns/lib/yellow_dog/dns/`:
- `query/resolver.ex` - Main resolver events
- `query/forwarder.ex` - Forward resolution events
- `query/recursive.ex` - Recursive resolution events
- `query/iterator.ex` - Iteration events
- `query/referral.ex` - Referral events
- `query/cache/manager.ex` - Cache operations events
- `query/cache/cleaner.ex` - Cache cleanup events
- `root_zone/fetcher.ex` - Root zone fetch events
- `root_zone/manager.ex` - Root zone management events

### Phase 2: Core Application (24 calls, P2)

Files in `apps/yellow_dog/lib/yellow_dog/`:
- `application.ex` - App lifecycle events
- `config.ex` - Configuration events
- `service_manager.ex` - Service orchestration events

### Phase 3: Web Console (12 calls, P3)

Files in `apps/yellow_dog_console/lib/yellow_dog/console/`:
- `live/dashboard_live.ex` - Dashboard events
- `live/settings_live.ex` - Settings events
- `service_manager.ex` - Console service events

### Phase 4: Infrastructure Libraries (7 calls, P3)

Files:
- `apps/abyss/lib/abyss/rate_limiter.ex` - Rate limiter events (excluding logger.ex)
- `apps/ex_dns/lib/dns/error.ex` - DNS error events

## Telemetry Event Naming

Following Constitution v1.3.0 pattern: `[:yellow_dog, <service>, <resource>, <action>]`

### DNS Query Events
```elixir
[:yellow_dog, :dns, :query, :start]
[:yellow_dog, :dns, :query, :complete]
[:yellow_dog, :dns, :query, :error]
[:yellow_dog, :dns, :query, :forward]
[:yellow_dog, :dns, :query, :recursive]
[:yellow_dog, :dns, :cache, :hit]
[:yellow_dog, :dns, :cache, :miss]
[:yellow_dog, :dns, :cache, :store]
[:yellow_dog, :dns, :cache, :cleanup]
[:yellow_dog, :dns, :root_zone, :fetch]
[:yellow_dog, :dns, :root_zone, :update]
```

### Application Events
```elixir
[:yellow_dog, :application, :start]
[:yellow_dog, :application, :stop]
[:yellow_dog, :config, :loaded]
[:yellow_dog, :config, :error]
[:yellow_dog, :service, :start]
[:yellow_dog, :service, :stop]
[:yellow_dog, :service, :error]
```

### Console Events
```elixir
[:yellow_dog, :console, :dashboard, :load]
[:yellow_dog, :console, :settings, :update]
[:yellow_dog, :console, :service, :action]
```

### Infrastructure Events
```elixir
[:abyss, :rate_limiter, :check]
[:abyss, :rate_limiter, :exceeded]
[:ex_dns, :error]
```

## Success Metrics

| Metric | Target | Verification |
|--------|--------|--------------|
| Logger calls migrated | 156 → 0 (excluding exclusions) | `grep -r "Logger\." apps/*/lib` |
| Tests passing | 100% | `mix test` |
| Compilation | No warnings | `mix compile --warnings-as-errors` |
| Format check | Pass | `mix format --check-formatted` |
| require Logger removed | All files | `grep -r "require Logger" apps/*/lib` |
