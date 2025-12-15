# Implementation Plan: E2E Service Tests

**Branch**: `001-e2e-service-tests` | **Date**: 2025-12-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-e2e-service-tests/spec.md`

## Summary

Implement end-to-end tests for DNS, mDNS, DHCPv4, and DHCPv6 services with standalone GitHub Actions workflows. Tests will start actual services on auto-selected ports, send real protocol messages, and verify correct responses. All tests placed in `e2e_test/` directory with mix task aliases for individual and combined execution.

## Technical Context

**Language/Version**: Elixir 1.18 with OTP 27/28
**Primary Dependencies**: ExUnit, ex_dns (DNS protocol), ex_dhcp (DHCP protocol), abyss (UDP transport)
**Storage**: N/A (in-memory test data only)
**Testing**: ExUnit with custom test helpers for service lifecycle management
**Target Platform**: Linux (GitHub Actions ubuntu-latest), local development
**Project Type**: Umbrella project - tests in `e2e_test/` at umbrella root
**Performance Goals**: All E2E tests complete within 2 minutes total
**Constraints**: Non-privileged ports only (auto-select via port 0), unicast for mDNS in CI
**Scale/Scope**: 4 service tests + 1 combined runner, ~20 test cases total

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Gate | Status | Notes |
|------|--------|-------|
| UDP via Abyss | PASS | E2E tests use services which use Abyss internally |
| Module naming (YellowDog.*) | PASS | Test helpers follow `E2ETest.*` pattern (test code) |
| Centralized config | PASS | Tests use `YellowDog.Config` for service configuration |
| CI compilation | PASS | E2E tests will compile with `--warnings-as-errors` |
| Test organization | PASS | E2E tests in dedicated `e2e_test/` directory |
| Telemetry events | PASS | Services emit telemetry; tests may verify events |
| 100% pass rate for infra libs | N/A | E2E tests don't modify infrastructure libraries |

**All gates pass. Proceeding to Phase 0.**

## Project Structure

### Documentation (this feature)

```text
specs/001-e2e-service-tests/
├── plan.md              # This file
├── spec.md              # Feature specification
├── checklist.md         # Implementation checklist
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── quickstart.md        # Phase 1 output
```

### Source Code (repository root)

```text
# E2E Test Structure
e2e_test/
├── test_helper.exs      # ExUnit setup, E2ETest.Helper module
├── dns_e2e_test.exs     # DNS service E2E tests
├── mdns_e2e_test.exs    # mDNS service E2E tests
├── dhcpv4_e2e_test.exs  # DHCPv4 service E2E tests
├── dhcpv6_e2e_test.exs  # DHCPv6 service E2E tests
└── support/
    ├── dns_client.ex    # DNS query helper
    ├── dhcp_client.ex   # DHCP message helper
    └── service_helper.ex # Service start/stop/wait helpers

# GitHub Actions
.github/workflows/
└── e2e.yml              # E2E test workflow

# Mix configuration (umbrella root)
mix.exs                  # Add test.e2e aliases
```

**Structure Decision**: E2E tests placed at umbrella root in `e2e_test/` directory. This keeps them separate from unit tests while allowing access to all umbrella applications. Support modules provide reusable helpers for service lifecycle and protocol interactions.

## Complexity Tracking

No constitution violations. No complexity justifications needed.
