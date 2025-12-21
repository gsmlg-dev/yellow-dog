# Implementation Plan: Service Diagnostics Page

**Branch**: `001-service-diagnostics` | **Date**: 2025-12-19 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-service-diagnostics/spec.md`

## Summary

Implement a Phoenix LiveView page at `/diagnostics` with 4 tabs (DNS, mDNS, DHCPv4, DHCPv6) for testing network services. Each tab provides forms for sending protocol-specific queries using the existing `ex_dns` and `ex_dhcp` libraries, displays request/response in both struct and raw hex views, and maintains a 10-entry query history per tab. Network operations use `start_async/3` for non-blocking UI.

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 27-28
**Primary Dependencies**: Phoenix LiveView 1.0, ex_dns (in_umbrella), ex_dhcp (in_umbrella), DaisyUI 5.0
**Storage**: LiveView assigns (session-scoped, ETS not required)
**Testing**: ExUnit with integration tests
**Target Platform**: Web browser (Phoenix LiveView)
**Project Type**: Web application (Phoenix umbrella app)
**Performance Goals**: Query response displayed within 5 seconds for responsive servers
**Constraints**: DHCP tabs require privileged ports (67/68, 546/547) - display warnings
**Scale/Scope**: Single-user diagnostics tool, 10 queries history per tab

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| Module Naming (`YellowDog.<AppName>.*`) | PASS | Will use `YellowDog.Console.DiagnosticsLive.*` |
| UDP Transport (Abyss) | N/A | This feature sends diagnostic queries, not a server |
| DNS Protocol (ex_dns) | PASS | Using `DNS.Message` for encoding/decoding |
| DHCP Protocol (ex_dhcp) | PASS | Using `DHCPv4.Message` and `DHCPv6.Message` |
| Phoenix LiveView Architecture | PASS | Using `use YellowDog.Console, :live_view` |
| DaisyUI Components | PASS | Using CoreComponents (tabs, cards, forms, badges) |
| Telemetry | PASS | Can emit diagnostic query events |
| Testing | PASS | Unit tests for message building, integration for UI |
| Code Quality | PASS | Will compile with --warnings-as-errors |

**Direct Socket Usage Note**: The constitution prohibits direct `:gen_udp` in protocol server applications but this diagnostic tool is a client-side utility for testing purposes. The `:gen_udp`/`:gen_tcp` usage is acceptable here as we are sending test queries, not implementing a server. This is analogous to using `dig` or `nslookup` - client tools that don't require the server infrastructure.

## Project Structure

### Documentation (this feature)

```text
specs/001-service-diagnostics/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (internal LiveView contracts)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/yellow_dog_console/lib/yellow_dog/console/
├── live/
│   └── diagnostics_live/
│       ├── diagnostics_live.ex      # Main LiveView with tabs
│       ├── dns_tab.ex               # DNS query form/results component
│       ├── mdns_tab.ex              # mDNS query form/results component
│       ├── dhcpv4_tab.ex            # DHCPv4 query form/results component
│       ├── dhcpv6_tab.ex            # DHCPv6 query form/results component
│       └── components/
│           ├── query_form.ex        # Reusable form component
│           ├── result_display.ex    # Struct/Raw view toggle component
│           ├── hex_dump.ex          # xxd-style hex dump component
│           └── query_history.ex     # Collapsible history panel
└── diagnostics/
    ├── dns_client.ex                # DNS query execution
    ├── mdns_client.ex               # mDNS query execution (multicast)
    ├── dhcpv4_client.ex             # DHCPv4 query execution (broadcast)
    ├── dhcpv6_client.ex             # DHCPv6 query execution (multicast)
    └── hex_formatter.ex             # Binary to xxd-style formatting

apps/yellow_dog_console/test/yellow_dog/console/
├── live/
│   └── diagnostics_live_test.exs    # LiveView integration tests
└── diagnostics/
    ├── dns_client_test.exs          # DNS client unit tests
    ├── mdns_client_test.exs         # mDNS client unit tests
    ├── dhcpv4_client_test.exs       # DHCPv4 client unit tests
    ├── dhcpv6_client_test.exs       # DHCPv6 client unit tests
    └── hex_formatter_test.exs       # Hex formatting tests
```

**Structure Decision**: Following Phoenix LiveView conventions with a dedicated `diagnostics_live/` directory for the main LiveView and tab components, plus a `diagnostics/` module for protocol client logic. This separates UI concerns from network operations.

## Complexity Tracking

No constitution violations requiring justification.

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Direct socket usage | Client-side `:gen_udp`/`:gen_tcp` | Diagnostic tool (not server), similar to CLI tools like `dig` |
| No Abyss dependency | Correct | Abyss is for UDP servers, not client queries |
