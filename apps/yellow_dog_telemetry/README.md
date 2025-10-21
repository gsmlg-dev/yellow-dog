# YellowDog.Telemetry

Centralized telemetry and logging for the YellowDog umbrella project.

## Features

- **Structured Logging**: Debug, info, warning, and error level logging with automatic metadata enrichment
- **Automatic App Detection**: Automatically detects which umbrella app is emitting logs based on module namespace
- **Span Tracking**: Track operation durations and performance with nested span support
- **Flexible Filtering**: Filter logs by app name, log level, or custom criteria
- **Multiple Output Formats**: Pretty (development), JSON (production), and minimal (testing) formats
- **Telemetry Integration**: Built on top of `:telemetry` library for extensibility

## Installation

In your umbrella app's `mix.exs`, add the dependency:

```elixir
def deps do
  [
    {:yellow_dog_telemetry, in_umbrella: true}
  ]
end
```

## Basic Usage

### Logging

```elixir
alias YellowDog.Telemetry

# Different log levels
Telemetry.debug("Processing request", %{client_ip: "192.168.1.1"})
Telemetry.info("DNS query received", %{domain: "example.com", type: "A"})
Telemetry.warning("Slow query detected", %{duration_ms: 150})
Telemetry.error("Failed to resolve domain", %{domain: "bad.example", error: :nxdomain})

# Lazy message evaluation (only evaluated if log level allows)
Telemetry.debug(fn -> "Expensive operation: #{inspect(large_data)}" end)
```

### Span Tracking

```elixir
# Automatic span with function wrapper
result = Telemetry.span("dns.query.resolve", %{domain: domain}, fn ->
  resolve_domain(domain)
end)

# Manual span control
span_id = Telemetry.start_span("dhcp.lease.allocate", %{mac: mac_address})
try do
  lease = allocate_lease(mac_address)
  Telemetry.end_span(span_id, %{ip: lease.ip, status: :success})
  lease
rescue
  error ->
    Telemetry.end_span(span_id, %{error: inspect(error), status: :failed})
    reraise error, __STACKTRACE__
end

# Nested spans for complex operations
Telemetry.span("dns.zone.load", %{zone: "example.com"}, fn ->
  records = Telemetry.span("dns.zone.read_file", %{}, fn ->
    File.read!("/var/zones/example.com.zone")
  end)

  Telemetry.span("dns.zone.parse", %{}, fn ->
    parse_zone_file(records)
  end)
end)
```

## App Name Detection

The module automatically detects which umbrella app is generating logs based on the calling module namespace:

- `YellowDog.Dns.*` → `:yellow_dog_dns`
- `YellowDog.Dhcpv4.*` → `:yellow_dog_dhcpv4`
- `YellowDog.Dhcpv6.*` → `:yellow_dog_dhcpv6`
- `YellowDog.Mdns.*` → `:yellow_dog_mdns`
- `YellowDogConsole.*` → `:yellow_dog_console`
- `YellowDog.*` → `:yellow_dog`

This allows for easy filtering and identification of log sources.

## Filtering

### Configuration-based Filtering

```elixir
# config/dev.exs
config :yellow_dog_telemetry,
  level: :debug,
  filter_apps: [:yellow_dog_dns],  # Only show DNS logs
  app_levels: %{
    yellow_dog_dns: :debug,
    yellow_dog_dhcpv4: :info
  }
```

### Runtime Filtering

```elixir
# Filter to specific apps
Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])

# Exclude specific apps
Telemetry.exclude_apps([:yellow_dog_console])

# Set per-app log levels
Telemetry.set_app_level(:yellow_dog_dns, :debug)
Telemetry.set_app_level(:yellow_dog_dhcpv4, :info)

# Reset to show all apps
Telemetry.show_all_apps()
```

## Configuration

### Development (config/dev.exs)

```elixir
config :yellow_dog_telemetry,
  level: :debug,
  format: :pretty,
  console_colors: true,
  show_spans: true,
  span_threshold_ms: 0  # Show all spans
```

### Test (config/test.exs)

```elixir
config :yellow_dog_telemetry,
  level: :warning,
  format: :minimal,
  show_spans: false
```

### Production (config/prod.exs)

```elixir
config :yellow_dog_telemetry,
  level: :info,
  format: :json,
  show_spans: true,
  span_threshold_ms: 100,  # Only log spans > 100ms
  app_levels: %{
    yellow_dog_console: :warning  # Less verbose for web console
  }
```

## Example Usage in Applications

### DNS Application

```elixir
defmodule YellowDog.Dns.Server do
  alias YellowDog.Telemetry

  def start_link(opts) do
    Telemetry.info("Starting DNS server", %{port: opts[:port]})
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def handle_query(domain, type) do
    Telemetry.span("dns.query.handle", %{domain: domain, type: type}, fn ->
      Telemetry.debug("Looking up domain", %{domain: domain, type: type})

      result = case lookup_domain(domain, type) do
        {:ok, records} ->
          Telemetry.info("Query resolved", %{domain: domain, records: length(records)})
          {:ok, records}

        {:error, reason} ->
          Telemetry.error("Query failed", %{domain: domain, error: reason})
          {:error, reason}
      end

      result
    end)
  end
end
```

### DHCP Application

```elixir
defmodule YellowDog.Dhcpv4.Handler do
  alias YellowDog.Telemetry

  def handle_request(packet) do
    Telemetry.span("dhcp.request.handle", %{type: packet.type, mac: packet.mac}, fn ->
      Telemetry.debug("Processing DHCP request", %{
        type: packet.type,
        client_mac: packet.mac
      })

      lease = Telemetry.span("dhcp.lease.allocate", %{mac: packet.mac}, fn ->
        allocate_lease(packet)
      end)

      Telemetry.info("Lease allocated", %{
        ip: lease.ip,
        mac: packet.mac,
        duration: lease.lease_time
      })

      lease
    end)
  end
end
```

## Integration with Existing Telemetry

The module emits standard `:telemetry` events that can be attached to:

```elixir
# Attach custom handler for DNS logs
:telemetry.attach(
  "my-dns-logger",
  [:yellow_dog, :log, :info],
  fn _event, _measurements, metadata, _config ->
    if metadata.app == :yellow_dog_dns do
      # Custom handling for DNS logs
      MyMetrics.increment_dns_queries()
    end
  end,
  nil
)

# Attach handler for span metrics
:telemetry.attach(
  "my-span-metrics",
  [:yellow_dog, :span, :stop],
  fn _event, measurements, metadata, _config ->
    MyMetrics.record_duration(metadata.name, measurements.duration_ms)
  end,
  nil
)
```

## Migration from Logger

To migrate from Elixir's Logger to YellowDog.Telemetry:

```elixir
# Before
require Logger
Logger.info("DNS query received", domain: "example.com")

# After
alias YellowDog.Telemetry
Telemetry.info("DNS query received", %{domain: "example.com"})
```

## Best Practices

1. **Use appropriate log levels**:
   - `:debug` - Detailed diagnostic information
   - `:info` - General informational messages
   - `:warning` - Warning messages for potentially harmful situations
   - `:error` - Error messages for error events

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
   - `service.operation.action`
   - Example: `dns.query.resolve`, `dhcp.lease.allocate`

5. **Filter logs in development** to focus on specific apps:
   ```elixir
   # In IEx
   iex> YellowDog.Telemetry.filter_apps([:yellow_dog_dns])
   ```

## License

This project is part of the YellowDog umbrella project.
