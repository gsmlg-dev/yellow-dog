# Quickstart: Telemetry-Based Logging System

**Feature Branch**: `001-telemetry-logging`
**Date**: 2025-12-22

## Overview

This guide explains how to use and extend the telemetry-based logging system in YellowDog.

---

## Using the Logging API

### Option 1: YellowDog.Telemetry Logging Functions (Recommended for simple logs)

Use the existing logging API for general-purpose logging:

```elixir
alias YellowDog.Telemetry

# Simple log messages
Telemetry.info("Server started on port 53")
Telemetry.debug("Processing query", %{query_name: "example.com"})
Telemetry.warning("High latency detected", %{latency_ms: 500})
Telemetry.error("Connection failed", %{reason: :timeout})
```

The module auto-detects which app is calling based on the module namespace.

### Option 2: Direct Telemetry Events (Recommended for protocol-specific events)

Use `:telemetry.execute/3` for structured protocol events:

```elixir
# DNS query received
:telemetry.execute(
  [:yellow_dog, :dns, :query, :received],
  %{count: 1},
  %{
    query_name: query.name,
    query_type: query.type,
    client_ip: client_ip
  }
)

# DHCP lease granted
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :granted],
  %{count: 1, lease_time: lease.duration},
  %{
    ip_address: lease.ip,
    client_mac: format_mac(lease.mac),
    pool_name: pool.name
  }
)
```

---

## Enabling/Disabling Logging

### Application Startup (Default)

Logger handlers are automatically attached during application startup in `YellowDog.Application.start/2`:

```elixir
# This is called automatically
YellowDog.Telemetry.attach_logger_handlers()
```

### Manual Control

```elixir
# Detach all logger handlers (silent mode)
YellowDog.Telemetry.detach_logger_handlers()

# Re-attach handlers
YellowDog.Telemetry.attach_logger_handlers()
```

---

## Configuration

### Log Level Filtering

Configure per-app log levels in `config/config.exs`:

```elixir
config :yellow_dog_telemetry,
  level: :info,  # Default level
  app_levels: %{
    yellow_dog_dns: :debug,      # Verbose DNS logging
    yellow_dog_dhcpv4: :info,    # Standard DHCP logging
    yellow_dog_mdns: :warning    # Quiet mDNS logging
  }
```

### Runtime Filtering

```elixir
# Filter to specific apps
YellowDog.Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])

# Exclude specific apps
YellowDog.Telemetry.exclude_apps([:yellow_dog_console])

# Set per-app level at runtime
YellowDog.Telemetry.set_app_level(:yellow_dog_dns, :debug)

# Reset to show all
YellowDog.Telemetry.show_all_apps()
```

### Log Format

Configure log format in `config/config.exs`:

```elixir
config :yellow_dog_telemetry,
  format: :pretty,      # :pretty | :json | :minimal
  console_colors: true  # Enable ANSI colors
```

---

## Adding New Telemetry Events

### Step 1: Emit the Event

In your protocol handler:

```elixir
defmodule YellowDog.MyProtocol.Handler do
  def handle_request(request, client_info) do
    # Emit received event
    :telemetry.execute(
      [:yellow_dog, :myprotocol, :request, :received],
      %{count: 1},
      %{client_ip: client_info.ip, request_type: request.type}
    )

    # Process request...
    result = process(request)

    # Emit completed event
    :telemetry.execute(
      [:yellow_dog, :myprotocol, :request, :completed],
      %{count: 1, duration_us: duration},
      %{client_ip: client_info.ip, result: result.status}
    )

    result
  end
end
```

### Step 2: Add Handler (if custom formatting needed)

In `YellowDog.Telemetry.LoggerHandlers`:

```elixir
def handle_myprotocol_event(event, measurements, metadata, config) do
  try do
    Logger.log(config.level, fn ->
      format_myprotocol_event(event, measurements, metadata)
    end)
  rescue
    _ -> :ok
  end
end

defp format_myprotocol_event([:yellow_dog, :myprotocol, :request, :received], _, meta) do
  "MyProtocol request from #{format_ip(meta.client_ip)}: #{meta.request_type}"
end
```

### Step 3: Register Handler

In `YellowDog.Telemetry.attach_logger_handlers/0`:

```elixir
:telemetry.attach_many(
  "yellow-dog-myprotocol-logger",
  [
    [:yellow_dog, :myprotocol, :request, :received],
    [:yellow_dog, :myprotocol, :request, :completed]
  ],
  &YellowDog.Telemetry.LoggerHandlers.handle_myprotocol_event/4,
  %{level: :info}
)
```

---

## Testing Telemetry Events

### Basic Event Verification

```elixir
defmodule YellowDog.MyProtocol.HandlerTest do
  use ExUnit.Case

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end

    :telemetry.attach(
      "test-handler",
      [:yellow_dog, :myprotocol, :request, :received],
      handler,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-handler")
    end)

    :ok
  end

  test "emits telemetry event on request" do
    # Trigger your code
    Handler.handle_request(%{type: :query}, %{ip: {127, 0, 0, 1}})

    # Verify event
    assert_receive {:telemetry, [:yellow_dog, :myprotocol, :request, :received], _, metadata}
    assert metadata.request_type == :query
    assert metadata.client_ip == {127, 0, 0, 1}
  end
end
```

### Suppress Log Output in Tests

In `test/test_helper.exs`:

```elixir
# Detach logger handlers during tests
YellowDog.Telemetry.detach_logger_handlers()

ExUnit.start()
```

---

## Migration Guide

### Before (Direct Logger)

```elixir
defmodule YellowDog.Dns.Handler do
  require Logger

  def handle_query(query, client) do
    Logger.info("DNS query: #{query.name} from #{inspect(client.ip)}")

    case resolve(query) do
      {:ok, result} ->
        Logger.debug("Resolved: #{inspect(result)}")
        result

      {:error, reason} ->
        Logger.error("Resolution failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

### After (Telemetry Events)

```elixir
defmodule YellowDog.Dns.Handler do
  def handle_query(query, client) do
    start_time = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:yellow_dog, :dns, :query, :received],
      %{count: 1},
      %{query_name: query.name, query_type: query.type, client_ip: client.ip}
    )

    case resolve(query) do
      {:ok, result} ->
        duration = System.monotonic_time(:microsecond) - start_time

        :telemetry.execute(
          [:yellow_dog, :dns, :query, :completed],
          %{count: 1, duration_us: duration, answer_count: length(result.answers)},
          %{query_name: query.name, response_code: result.rcode, client_ip: client.ip}
        )

        result

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :error],
          %{count: 1},
          %{query_name: query.name, error: reason, client_ip: client.ip}
        )

        {:error, reason}
    end
  end
end
```

---

## Best Practices

1. **Use lazy message formatting** - Always use `fn -> message end` in Logger.log
2. **Include count measurement** - Every event should have `%{count: 1}` minimum
3. **Use IP tuples** - Format as `{192, 168, 1, 1}`, not strings
4. **Format MACs consistently** - Use "AA:BB:CC:DD:EE:FF" format
5. **Wrap handlers in try/catch** - Handlers must not crash
6. **Follow naming convention** - `[:yellow_dog, <service>, <resource>, <action>]`
7. **Test event emission** - Attach test handlers to verify events fire
