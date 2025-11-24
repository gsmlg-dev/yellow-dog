# Project Memory

## Logging and Telemetry Standards

### YellowDog.Telemetry - Centralized Telemetry System

**ALWAYS** use `YellowDog.Telemetry` for all messaging, logging, and performance tracking instead of Elixir's built-in `Logger`.

#### Core Features
- **Structured Logging**: Debug, info, warning, and error level logging with automatic metadata
- **Automatic App Detection**: Detects which umbrella app is logging based on module namespace
- **Span Tracking**: Performance monitoring with nested span support
- **Flexible Filtering**: Filter by app name, log level, or custom criteria
- **Multiple Formats**: Pretty (dev), JSON (prod), Minimal (test)

#### Logging API

```elixir
alias YellowDog.Telemetry

# Basic logging
Telemetry.debug("Processing request", %{client_ip: "192.168.1.1"})
Telemetry.info("DNS query received", %{domain: "example.com", type: "A"})
Telemetry.warning("Slow query detected", %{duration_ms: 150})
Telemetry.error("Failed to resolve", %{domain: "bad.example", error: :nxdomain})

# Lazy evaluation (for expensive operations)
Telemetry.debug(fn -> "Expensive: #{inspect(large_data)}" end)
```

#### Span Tracking for Performance

```elixir
# Automatic span wrapper
result = Telemetry.span("dns.query.resolve", %{domain: domain}, fn ->
  resolve_domain(domain)
end)

# Manual span control
span_id = Telemetry.start_span("dhcp.lease.allocate", %{mac: mac})
try do
  lease = allocate_lease(mac)
  Telemetry.end_span(span_id, %{ip: lease.ip, status: :success})
  lease
rescue
  error ->
    Telemetry.end_span(span_id, %{error: inspect(error), status: :failed})
    reraise error, __STACKTRACE__
end

# Nested spans for complex operations
Telemetry.span("dns.zone.load", %{zone: "example.com"}, fn ->
  records = Telemetry.span("dns.zone.read", %{}, fn ->
    File.read!("/var/zones/example.com.zone")
  end)

  Telemetry.span("dns.zone.parse", %{}, fn ->
    parse_zone_file(records)
  end)
end)
```

#### App Name Auto-Detection

The module automatically detects which umbrella app is generating logs:
- `YellowDog.Dns.*` → `:yellow_dog_dns`
- `YellowDog.Dhcpv4.*` → `:yellow_dog_dhcpv4`
- `YellowDog.Dhcpv6.*` → `:yellow_dog_dhcpv6`
- `YellowDog.Mdns.*` → `:yellow_dog_mdns`
- `YellowDogConsole.*` → `:yellow_dog_console`
- `YellowDog.*` → `:yellow_dog`

#### Filtering Logs

```elixir
# In config files
config :yellow_dog_telemetry,
  level: :debug,
  filter_apps: [:yellow_dog_dns],  # Only show DNS logs
  app_levels: %{
    yellow_dog_dns: :debug,
    yellow_dog_dhcpv4: :info
  }

# Runtime filtering in IEx
iex> YellowDog.Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])
iex> YellowDog.Telemetry.set_app_level(:yellow_dog_dns, :debug)
iex> YellowDog.Telemetry.show_all_apps()  # Reset filtering
```

#### Environment Configuration

**Development** (`config/dev.exs`):
- Level: `:debug`
- Format: `:pretty` (with colors, app-specific coloring)
- Show all spans
- Span threshold: 0ms (show all)

**Test** (`config/test.exs`):
- Level: `:warning`
- Format: `:minimal`
- Spans disabled

**Production** (`config/prod.exs`):
- Level: `:info`
- Format: `:json`
- Span threshold: 100ms (only log slow operations)
- Per-app levels configured

#### Migration from Logger

```elixir
# Before
require Logger
Logger.info("DNS query received", domain: "example.com")
Logger.debug("Processing...")

# After
alias YellowDog.Telemetry
Telemetry.info("DNS query received", %{domain: "example.com"})
Telemetry.debug("Processing...")
```

#### Best Practices

1. **Use appropriate log levels**:
   - `:debug` - Detailed diagnostic information
   - `:info` - General informational messages
   - `:warning` - Potentially harmful situations
   - `:error` - Error events

2. **Include relevant metadata**:
   ```elixir
   Telemetry.info("Query resolved", %{
     domain: domain,
     type: type,
     ttl: ttl,
     records_count: length(records)
   })
   ```

3. **Use span tracking for performance-critical operations**:
   ```elixir
   Telemetry.span("expensive.operation", %{}, fn ->
     # Expensive operation here
   end)
   ```

4. **Name spans consistently** using dot notation:
   - Format: `service.operation.action`
   - Examples: `dns.query.resolve`, `dhcp.lease.allocate`, `dns.zone.load`

5. **Always alias the module** at the top of your module:
   ```elixir
   defmodule YellowDog.Dns.Server do
     alias YellowDog.Telemetry

     # Use Telemetry.info(), Telemetry.debug(), etc.
   end
   ```

#### Telemetry Events Emitted

The module emits standard `:telemetry` events that can be attached to:
- `[:yellow_dog, :log, :debug|:info|:warning|:error]` - Log events
- `[:yellow_dog, :span, :start]` - Span start events
- `[:yellow_dog, :span, :stop]` - Span stop events (includes duration)

#### Integration Notes

- All apps in the umbrella should depend on `:yellow_dog_telemetry`
- The telemetry app runs automatically as part of the application supervision tree
- Handlers are attached on application start
- Supports integration with external metrics systems (Prometheus, StatsD, etc.)

#### Documentation

Full documentation available in `apps/yellow_dog_telemetry/README.md`
