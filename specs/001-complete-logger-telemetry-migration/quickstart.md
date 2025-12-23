# Quickstart: Logger to Telemetry Migration Guide

**Feature**: Complete Logger to Telemetry Migration
**Date**: 2025-12-23

## Overview

This guide shows how to migrate Logger calls to telemetry events. Follow these patterns for each file being migrated.

## Step 1: Identify Logger Calls

Find all Logger calls in the file:

```bash
# In a specific file
grep -n "Logger\." apps/yellow_dog_dns/lib/yellow_dog/dns/query/resolver.ex

# Common patterns to find:
Logger.info("message")
Logger.warn("message")
Logger.error("message")
Logger.debug("message")
Logger.log(:level, "message")
```

## Step 2: Remove `require Logger`

Delete the require statement from the file:

```elixir
# REMOVE THIS LINE:
require Logger
```

## Step 3: Replace Logger Calls

### Pattern A: Info/Debug Messages

**Before:**
```elixir
Logger.info("DNS query received: #{inspect(query)}")
```

**After:**
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :received],
  %{count: 1},
  %{source: __MODULE__, query: query}
)
```

### Pattern B: Timing/Duration Messages

**Before:**
```elixir
Logger.info("Query completed in #{duration}ms")
```

**After:**
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :complete],
  %{duration_ms: duration, count: 1},
  %{source: __MODULE__, query: query, result: result}
)
```

### Pattern C: Error Messages

**Before:**
```elixir
Logger.error("Failed to resolve query: #{inspect(reason)}")
```

**After:**
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :error],
  %{count: 1},
  %{source: __MODULE__, query: query, reason: reason, severity: :error}
)
```

### Pattern D: Warning Messages

**Before:**
```elixir
Logger.warn("Cache miss for #{domain}")
```

**After:**
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :cache, :miss],
  %{count: 1},
  %{source: __MODULE__, query_name: domain, query_type: type}
)
```

### Pattern E: Debug Messages

**Before:**
```elixir
Logger.debug("Forwarding to upstream: #{upstream}")
```

**After:**
```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :forward],
  %{count: 1},
  %{source: __MODULE__, query_name: domain, upstream: upstream}
)
```

### Pattern F: Conditional Logging

**Before:**
```elixir
if verbose do
  Logger.debug("Detailed info: #{inspect(data)}")
end
```

**After:**
```elixir
# Always emit telemetry; handler decides whether to log
:telemetry.execute(
  [:yellow_dog, :dns, :query, :debug],
  %{count: 1},
  %{source: __MODULE__, data: data, level: :debug}
)
```

## Step 4: Event Naming Convention

Follow this pattern: `[:app, :component, :resource, :action]`

| App | Component | Resource | Action |
|-----|-----------|----------|--------|
| `:yellow_dog` | `:dns` | `:query` | `:start`, `:complete`, `:error` |
| `:yellow_dog` | `:dns` | `:cache` | `:hit`, `:miss`, `:store`, `:cleanup` |
| `:yellow_dog` | `:dns` | `:root_zone` | `:fetch`, `:update` |
| `:yellow_dog` | `:application` | `:lifecycle` | `:start`, `:stop` |
| `:yellow_dog` | `:config` | `:loading` | `:loaded`, `:error` |
| `:yellow_dog` | `:service` | `:state` | `:start`, `:stop`, `:error` |
| `:yellow_dog` | `:console` | `:dashboard` | `:load` |
| `:yellow_dog` | `:console` | `:settings` | `:update` |
| `:abyss` | `:rate_limiter` | `:check` | `:allowed`, `:exceeded` |
| `:ex_dns` | `:error` | `:parse` | `:raised` |

## Step 5: Measurements

Include relevant numeric values:

```elixir
# Timing events
%{duration_ms: duration, count: 1}

# Count-only events
%{count: 1}

# Cache events
%{count: 1, entries_removed: removed, entries_remaining: remaining}

# Error events
%{count: 1, error_count: 1}
```

## Step 6: Metadata

Include context for debugging:

```elixir
%{
  source: __MODULE__,           # Always include
  query_name: domain,           # Domain being queried
  query_type: type,             # Record type
  result: result,               # Success/error indicator
  reason: reason,               # Error reason (if applicable)
  severity: :error,             # For error events
  timestamp: System.system_time(:millisecond)  # Optional
}
```

## Step 7: Verify Migration

After migrating each file:

```bash
# Check no Logger calls remain
grep -n "Logger\." apps/path/to/file.ex

# Check require Logger is removed
grep -n "require Logger" apps/path/to/file.ex

# Compile to verify no warnings
mix compile --warnings-as-errors

# Run tests
mix test apps/path/to/app
```

## Step 8: Update Tests

Remove `capture_log` assertions:

**Before:**
```elixir
import ExUnit.CaptureLog

test "logs error on failure" do
  assert capture_log(fn ->
    perform_operation()
  end) =~ "error message"
end
```

**After:**
```elixir
test "emits telemetry on failure" do
  ref = make_ref()

  :telemetry.attach(
    "test-#{inspect(ref)}",
    [:yellow_dog, :dns, :query, :error],
    fn _event, measurements, metadata, pid ->
      send(pid, {:telemetry, measurements, metadata})
    end,
    self()
  )

  perform_operation()

  assert_receive {:telemetry, %{count: 1}, %{reason: _}}

  :telemetry.detach("test-#{inspect(ref)}")
end
```

## Example: Complete File Migration

### Before Migration

```elixir
defmodule YellowDog.Dns.Query.Resolver do
  require Logger

  def resolve(query) do
    Logger.debug("Starting resolution for #{query.name}")
    start_time = System.monotonic_time(:millisecond)

    case do_resolve(query) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("Resolved #{query.name} in #{duration}ms")
        {:ok, result}

      {:error, reason} ->
        Logger.error("Failed to resolve #{query.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

### After Migration

```elixir
defmodule YellowDog.Dns.Query.Resolver do
  def resolve(query) do
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :start],
      %{count: 1},
      %{source: __MODULE__, query_name: query.name, query_type: query.type}
    )

    start_time = System.monotonic_time(:millisecond)

    case do_resolve(query) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:yellow_dog, :dns, :query, :complete],
          %{duration_ms: duration, count: 1},
          %{source: __MODULE__, query_name: query.name, result: :success}
        )

        {:ok, result}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{duration_ms: duration, count: 1},
          %{source: __MODULE__, query_name: query.name, reason: reason, severity: :error}
        )

        {:error, reason}
    end
  end
end
```

## Checklist

For each file being migrated:

- [ ] Remove `require Logger` statement
- [ ] Replace each `Logger.info/1` call with telemetry event
- [ ] Replace each `Logger.warn/1` call with telemetry event
- [ ] Replace each `Logger.error/1` call with telemetry event
- [ ] Replace each `Logger.debug/1` call with telemetry event
- [ ] Use correct event naming: `[:app, :component, :resource, :action]`
- [ ] Include `source: __MODULE__` in metadata
- [ ] Include timing in measurements where applicable
- [ ] Verify file compiles without warnings
- [ ] Update related tests to not use `capture_log`
- [ ] Run tests to verify behavior unchanged

## Files to Migrate (Reference)

### Phase 1: DNS Query System (P1)
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/resolver.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/forwarder.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/recursive.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/iterator.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/referral.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/manager.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query/cache/cleaner.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/fetcher.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/root_zone/manager.ex`

### Phase 2: Core Application (P2)
- `apps/yellow_dog/lib/yellow_dog/application.ex`
- `apps/yellow_dog/lib/yellow_dog/config.ex`
- `apps/yellow_dog/lib/yellow_dog/service_manager.ex`

### Phase 3: Web Console (P3)
- `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex`
- `apps/yellow_dog_console/lib/yellow_dog/console/service_manager.ex`

### Phase 4: Infrastructure (P3)
- `apps/abyss/lib/abyss/rate_limiter.ex`
- `apps/ex_dns/lib/dns/error.ex`
