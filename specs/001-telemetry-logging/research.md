# Research: Telemetry-Based Logging System

**Feature Branch**: `001-telemetry-logging`
**Date**: 2025-12-22

## Research Tasks

### 1. Existing YellowDog.Telemetry Architecture

**Decision**: Extend existing `YellowDog.Telemetry` module rather than create new infrastructure.

**Rationale**:
- The module already provides a comprehensive logging API (`info/2`, `debug/2`, `warning/2`, `error/2`)
- Existing handlers in `YellowDog.Telemetry.Application` handle `[:yellow_dog, :log, *]` events
- Span tracking is already implemented with `[:yellow_dog, :span, *]` events
- Adding protocol-specific events follows the same pattern

**Current Implementation**:
```elixir
# Existing event structure in YellowDog.Telemetry
[:yellow_dog, :log, :debug]
[:yellow_dog, :log, :info]
[:yellow_dog, :log, :warning]
[:yellow_dog, :log, :error]
[:yellow_dog, :span, :start]
[:yellow_dog, :span, :stop]
```

**Alternatives Considered**:
1. Create separate logger module - Rejected: duplicates existing functionality
2. Use direct Logger calls only - Rejected: violates constitution requirements
3. Third-party telemetry adapter - Rejected: adds external dependency

---

### 2. Telemetry Handler Attachment Patterns

**Decision**: Use `:telemetry.attach_many/4` for batch handler attachment with unique handler IDs per service.

**Rationale**:
- More efficient than multiple `:telemetry.attach/4` calls
- Unique handler IDs allow selective detachment for testing
- Pattern already used in `YellowDog.Telemetry.Application`

**Best Practices**:
```elixir
# Handler attachment pattern
:telemetry.attach_many(
  "yellow-dog-dns-logger",           # Unique handler ID
  [
    [:yellow_dog, :dns, :query, :received],
    [:yellow_dog, :dns, :query, :completed],
    [:yellow_dog, :dns, :query, :error]
  ],
  &handle_dns_event/4,
  %{level: :info}                     # Config passed to handler
)

# Handler detachment pattern
:telemetry.detach("yellow-dog-dns-logger")
```

**Alternatives Considered**:
1. Single handler for all events - Rejected: harder to configure per-service log levels
2. Separate handler per event - Rejected: excessive handler registrations

---

### 3. Log Message Formatting Strategy

**Decision**: Use lazy message formatting with anonymous functions to defer string interpolation.

**Rationale**:
- Constitution requirement FR-006 mandates lazy formatting
- Prevents performance overhead when log level filters message
- Standard Elixir Logger best practice

**Implementation Pattern**:
```elixir
# In handler function
def handle_dns_query(_event, measurements, metadata, config) do
  Logger.log(config.level, fn ->
    "DNS query: #{metadata.query_name} (#{metadata.query_type}) from #{format_ip(metadata.client_ip)}"
  end)
end
```

**Alternatives Considered**:
1. Eager string formatting - Rejected: performance impact, violates FR-006
2. Pre-formatted messages in events - Rejected: less flexible, larger event payloads

---

### 4. Event Naming Convention Analysis

**Decision**: Follow existing constitution pattern `[:yellow_dog, <service>, <resource>, <action>]`.

**Rationale**:
- Matches existing conventions in `YellowDog.Telemetry` documentation
- Consistent with Abyss span events (`[:yellow_dog, :listener, :start]`)
- Easy to filter by prefix for service-specific logging

**Event Catalog**:

| Service | Resource | Actions |
|---------|----------|---------|
| dns | query | received, completed, error |
| dns | cache | hit, miss |
| dns | zone | loaded, error |
| dns | server | started, stopped |
| dhcpv4 | lease | requested, granted, released, expired, declined |
| dhcpv4 | server | started, stopped |
| dhcpv6 | lease | requested, granted, released, expired, declined |
| dhcpv6 | server | started, stopped |
| mdns | service | registered, unregistered, announced |
| mdns | query | received |
| mdns | response | sent |
| mdns | server | started, stopped |

---

### 5. Error Handling in Telemetry Handlers

**Decision**: Wrap handler logic in try/catch to prevent crashes affecting service operation.

**Rationale**:
- Constitution requirement FR-010: handlers must not crash
- Telemetry library detaches handlers that raise exceptions
- Silent failure preferred over service disruption

**Implementation Pattern**:
```elixir
def handle_event(event, measurements, metadata, config) do
  try do
    do_handle_event(event, measurements, metadata, config)
  rescue
    error ->
      # Log error but don't crash
      Logger.error("Telemetry handler error: #{inspect(error)}")
  catch
    kind, value ->
      Logger.error("Telemetry handler #{kind}: #{inspect(value)}")
  end
end
```

**Alternatives Considered**:
1. Let handlers crash - Rejected: violates FR-010, disrupts logging
2. Return error tuple - N/A: telemetry handlers return `:ok` only

---

### 6. Migration Strategy

**Decision**: Incremental migration per service, using `YellowDog.Telemetry.info/2` etc. for simple cases and `:telemetry.execute/3` for protocol-specific events.

**Rationale**:
- Allows gradual rollout with verification
- Existing `YellowDog.Telemetry.info/2` API auto-detects calling app
- Protocol events need explicit `:telemetry.execute/3` for proper event naming

**Migration Patterns**:

```elixir
# Simple logging (use existing API)
# Before:
Logger.info("DNS server started on port #{port}")
# After:
YellowDog.Telemetry.info("DNS server started on port #{port}", %{port: port})

# Protocol events (use telemetry.execute)
# Before:
Logger.info("DHCP lease granted: #{ip} to #{mac}")
# After:
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :granted],
  %{count: 1},
  %{ip: ip, mac: mac, lease_time: lease_time}
)
```

**Alternatives Considered**:
1. Big-bang migration - Rejected: higher risk, harder to verify parity
2. Automated code transformation - Rejected: context-specific formatting needed

---

### 7. Testing Strategy

**Decision**: Use telemetry test handlers that capture events for assertion.

**Rationale**:
- Constitution requirement SC-007: test suites can attach custom handlers
- Avoids polluting test output while verifying behavior
- Pattern already used in existing `telemetry_test.exs`

**Implementation Pattern**:
```elixir
defmodule YellowDog.Telemetry.LoggerHandlersTest do
  use ExUnit.Case

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    :telemetry.attach("test-handler", [:yellow_dog, :dns, :query, :received], handler, nil)

    on_exit(fn ->
      :telemetry.detach("test-handler")
    end)

    :ok
  end

  test "DNS query event is emitted" do
    # Trigger event
    :telemetry.execute([:yellow_dog, :dns, :query, :received], %{}, %{query_name: "example.com"})

    assert_receive {:telemetry_event, [:yellow_dog, :dns, :query, :received], _, metadata}
    assert metadata.query_name == "example.com"
  end
end
```

---

### 8. File Count Analysis

**Decision**: Focus migration on protocol apps (37 files), exclude infrastructure (3 files), evaluate core/console (6 files).

**Breakdown**:
- **In Scope** (37 files):
  - DNS: 14 files
  - DHCPv4: 7 files
  - DHCPv6: 6 files
  - mDNS: 10 files

- **Out of Scope** (3 files):
  - abyss: 2 files (infrastructure library)
  - ex_dns: 1 file (infrastructure library)

- **Evaluate** (6 files):
  - yellow_dog core: 3 files (application startup logging)
  - yellow_dog_console: 3 files (may use Phoenix telemetry)

---

## Summary

All technical decisions have been made. No NEEDS CLARIFICATION items remain.

**Key Decisions**:
1. Extend existing `YellowDog.Telemetry` with `attach_logger_handlers/0`
2. Use `:telemetry.attach_many/4` for batch registration
3. Lazy message formatting with anonymous functions
4. Follow `[:yellow_dog, <service>, <resource>, <action>]` naming
5. Error-safe handlers with try/catch
6. Incremental migration per service
7. Test handlers that capture events for assertions
8. 37 files in scope, 3 out of scope, 6 to evaluate
