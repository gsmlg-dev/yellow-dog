# Implementation Plan: Process Map

**Branch**: `001-process-map` | **Date**: 2024-12-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-process-map/spec.md`

## Summary

Add a "Process Map" page to the YellowDog web console under the System section that displays an interactive tree diagram of Erlang/OTP supervision hierarchies for YellowDog umbrella applications. Users can click on process nodes to view detailed status information including PID, registered name, current function, message queue length, and memory usage. The tree updates in near real-time and supports expand/collapse navigation.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27-28
**Primary Dependencies**: Phoenix LiveView 1.0, DaisyUI 5.0, Heroicons
**Storage**: N/A (in-memory process introspection only)
**Testing**: ExUnit, LiveView testing helpers
**Target Platform**: Web browser (Phoenix LiveView)
**Project Type**: Umbrella Elixir project with Phoenix LiveView console
**Performance Goals**: Page load <2s, click response <1s, 200 processes displayed smoothly
**Constraints**: Read-only process viewing, YellowDog apps only (not all BEAM processes)
**Scale/Scope**: ~50-200 processes across 7 YellowDog umbrella applications

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Rule | Status | Notes |
|------|--------|-------|
| Module naming (YellowDog.Console.*) | ✅ PASS | Will use `YellowDog.Console.ProcessMapLive` |
| Phoenix 1.8 patterns | ✅ PASS | Use `use YellowDog.Console, :live_view` |
| DaisyUI components | ✅ PASS | Use existing CoreComponents |
| Telemetry for logging | ✅ PASS | Use telemetry events, not direct Logger |
| No direct :gen_udp | ✅ N/A | No UDP involved |
| No direct :gen_tcp | ✅ N/A | No TCP involved |
| Bun for JS assets | ✅ PASS | Standard console asset pipeline |
| Warnings as errors | ✅ PASS | Will compile clean |

**GATE PASSED** - No constitution violations.

## Project Structure

### Documentation (this feature)

```text
specs/001-process-map/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── contracts/           # Phase 1 output (N/A - no API contracts)
```

### Source Code (repository root)

```text
apps/yellow_dog_console/lib/yellow_dog/console/
├── router.ex                          # Add /process-map route
├── components/layouts.ex              # Add Process Map sidebar item
├── live/
│   └── process_map_live.ex            # Main LiveView page
├── services/
│   └── process_inspector.ex           # Process tree introspection logic

apps/yellow_dog_console/test/yellow_dog/console/
├── live/
│   └── process_map_live_test.exs      # LiveView tests
├── services/
│   └── process_inspector_test.exs     # Unit tests

apps/yellow_dog_console/assets/css/
└── app.css                            # Tree visualization styles (if needed)
```

**Structure Decision**: Single LiveView page with a dedicated service module for process introspection. Follows existing console patterns (e.g., `LogsLive`, `DiagnosticsLive`).

## Complexity Tracking

> **No violations to justify** - This feature follows standard console patterns.

---

## Phase 0: Research

### Research Tasks

1. **OTP Supervision Tree Introspection** - How to enumerate supervision trees for specific applications
2. **Process Information Retrieval** - Best practices for `:erlang.process_info/2` usage
3. **Tree Visualization in LiveView** - CSS/HTML patterns for interactive tree diagrams
4. **Real-time Updates** - Efficient polling/push strategies for process changes

### Findings

See [research.md](./research.md) for detailed findings.

---

## Phase 1: Design

### Data Model

See [data-model.md](./data-model.md) for entity definitions.

### Contracts

No external API contracts needed - this is a LiveView page with internal Elixir function calls.

### Quickstart

See [quickstart.md](./quickstart.md) for development setup.
