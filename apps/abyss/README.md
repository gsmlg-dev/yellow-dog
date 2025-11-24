# Abyss

[![release](https://github.com/gsmlg-dev/abyss/actions/workflows/release.yml/badge.svg)](https://github.com/gsmlg-dev/abyss/actions/workflows/release.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/abyss.svg)](https://hex.pm/packages/abyss)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/abyss)

Abyss is a modern, pure Elixir UDP server library that provides a high-performance foundation for building UDP-based services like DNS servers, DHCP servers, or custom UDP applications. It implements a supervisor-based architecture with connection pooling and pluggable transport modules.

## Features

- **High Performance**: Supervisor-based architecture with configurable connection pooling
- **Flexible Handler System**: Pluggable handler modules for custom protocol implementations
- **Real-time Metrics**: Built-in telemetry with connection counts, throughput rates, and response times
- **Security Features**: Built-in rate limiting and packet size validation
- **Broadcast Support**: Native support for broadcast and multicast applications
- **Graceful Shutdown**: Coordinated shutdown with configurable timeouts
- **Extensible Transport**: Pluggable transport layer (currently UDP)

## Installation

The package can be installed by adding `abyss` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:abyss, "~> 0.4.0"}
  ]
end
```

## Quick Start

### Basic Echo Server

```elixir
defmodule MyEchoHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Echo the data back to the client
    Abyss.Transport.UDP.send(state.socket, ip, port, data)
    {:continue, state}
  end
end

# Start the server
{:ok, _pid} = Abyss.start_link([
  handler_module: MyEchoHandler,
  port: 1234,
  num_listeners: 10
])
```

### Monitoring and Telemetry

Abyss provides built-in real-time metrics for monitoring server performance:

```elixir
# Get current metrics
metrics = Abyss.Telemetry.get_metrics()
# => %{
#   connections_active: 15,
#   connections_total: 1250,
#   accepts_total: 1250,
#   responses_total: 1198,
#   accepts_per_second: 25,
#   responses_per_second: 23
# }

# Set up response time monitoring
:telemetry.attach_many(
  "response-monitor",
  [[:abyss, :metrics, :response_time]],
  fn [:abyss, :metrics, :response_time], measurements, _metadata, _config ->
    IO.puts("Response time: \#{measurements.response_time}ms")
  end,
  %{}
)

# Reset metrics
Abyss.Telemetry.reset_metrics()
```

### Testing with netcat

```bash
# Send a test packet
echo "Hello, UDP" | nc -4 -u -w1 127.0.0.1 1234

# Continuous testing
while true; do echo "Hello, UDP $(date +%T)" | nc -4 -u -w1 127.0.0.1 1234; done
```

## API Reference

### Core Functions

#### `start_link/1`

Starts an Abyss server with the given options.

```elixir
@spec start_link(options()) :: Supervisor.on_start()
```

**Options:**
- `handler_module` (required) - Module implementing `Abyss.Handler` behavior
- `port` - UDP port to listen on (default: 4000)
- `num_listeners` - Number of listener processes (default: 100)
- `num_connections` - Max concurrent connections (default: 16_384)
- `transport_options` - Keyword list passed to UDP transport
- `read_timeout` - Connection read timeout (default: 60_000ms)
- `shutdown_timeout` - Graceful shutdown timeout (default: 15_000ms)
- `rate_limit_enabled` - Enable rate limiting (default: false)
- `rate_limit_max_packets` - Max packets per window (default: 1000)
- `rate_limit_window_ms` - Rate limit window in ms (default: 1000)
- `max_packet_size` - Maximum packet size in bytes (default: 8192)
- `broadcast` - Enable broadcast mode (default: false)

#### `stop/2`

Stops the server gracefully, waiting for connections to finish.

```elixir
@spec stop(Supervisor.supervisor(), timeout()) :: :ok
```

#### `suspend/1` and `resume/1`

Temporarily stop accepting new connections while maintaining existing ones.

```elixir
def suspend(supervisor), do: Abyss.Server.suspend(supervisor)
def resume(supervisor), do: Abyss.Server.resume(supervisor)
```

### Handler Behavior

Implement the `Abyss.Handler` behavior to process UDP packets:

```elixir
defmodule MyHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Process incoming UDP packet
    response = process_data(data)

    # Send response back to client
    Abyss.Transport.UDP.send(state.socket, ip, port, response)

    {:continue, state}  # Continue handling more packets
    # or
    {:close, state}     # Close connection after response
  end

  # Optional callbacks
  @impl true
  def handle_timeout(state) do
    Logger.warn("Connection timed out")
    {:close, state}
  end

  @impl true
  def handle_error(reason, state) do
    Logger.error("Handler error: #{inspect(reason)}")
    {:continue, state}
  end

  @impl true
  def init(state) do
    {:ok, Map.put(state, :counter, 0)}
  end

  @impl true
  def terminate(_reason, state) do
    # Cleanup resources
    :ok
  end
end
```

### Configuration Examples

#### Basic Configuration

```elixir
Abyss.start_link([
  handler_module: MyHandler,
  port: 8080
])
```

#### Performance Tuning

```elixir
Abyss.start_link([
  handler_module: MyHandler,
  port: 8080,
  num_listeners: 200,      # Increase for high throughput
  num_connections: 32_768, # Allow more concurrent connections
  read_timeout: 30_000     # Shorter timeout for faster cleanup
])
```

#### Security Configuration

```elixir
Abyss.start_link([
  handler_module: MyHandler,
  port: 8080,
  rate_limit_enabled: true,
  rate_limit_max_packets: 100,  # Lower limit for strict rate limiting
  rate_limit_window_ms: 1000,
  max_packet_size: 1024         # Limit packet size to prevent DoS
])
```

#### Broadcast/Multicast Configuration

```elixir
Abyss.start_link([
  handler_module: MyBroadcastHandler,
  port: 67,  # DHCP port
  broadcast: true,
  transport_options: [
    broadcast: true,
    multicast_if: {255, 255, 255, 255},
    reuseaddr: true,
    reuseport: true
  ]
])
```

### Telemetry Events

Abyss emits comprehensive telemetry events for monitoring:

#### Listener Events
- `[:abyss, :listener, :start]`
- `[:abyss, :listener, :ready]`
- `[:abyss, :listener, :waiting]`
- `[:abyss, :listener, :receiving]`
- `[:abyss, :listener, :stop]`

#### Connection Events
- `[:abyss, :connection, :start]`
- `[:abyss, :connection, :ready]`
- `[:abyss, :connection, :send]`
- `[:abyss, :connection, :recv]`
- `[:abyss, :connection, :stop]`

#### Security Events
- `[:abyss, :listener, :rate_limit_exceeded]`
- `[:abyss, :listener, :packet_too_large]`

#### Enabling Logging

```elixir
# Attach structured logger at different levels
Abyss.Logger.attach_logger(:error)   # Errors only
Abyss.Logger.attach_logger(:info)    # General events
Abyss.Logger.attach_logger(:debug)   # Detailed debugging
Abyss.Logger.attach_logger(:trace)   # Verbose tracing
```

### Performance Considerations

#### Tuning Guidelines

1. **Listener Pool Size** (`num_listeners`)
   - Default: 100
   - Increase for high-throughput scenarios
   - Typical range: 10-1000

2. **Connection Limits** (`num_connections`)
   - Default: 16_384
   - Based on available memory and expected load
   - Use `:infinity` for unlimited (with caution)

3. **Rate Limiting**
   - Enable for public-facing services
   - Adjust based on expected traffic patterns
   - Monitor `[:abyss, :listener, :rate_limit_exceeded]` events

4. **Buffer Sizes**
   - Configure via `transport_options`
   ```elixir
   transport_options: [
     recbuf: 8192,  # Receive buffer
     sndbuf: 8192   # Send buffer
   ]
   ```

#### Monitoring

Monitor key metrics via telemetry:

```elixir
:telemetry.attach_many(
  "abyss-monitor",
  [
    [:abyss, :listener, :start],
    [:abyss, :connection, :start],
    [:abyss, :listener, :rate_limit_exceeded]
  ],
  &handle_metrics/4,
  %{}
)
```

## Security Best Practices

### Production Deployment

When deploying Abyss to production, consider these security configurations:

```elixir
Abyss.start_link([
  handler_module: MyHandler,
  port: 8080,

  # Enable rate limiting for DoS protection
  rate_limit_enabled: true,
  rate_limit_max_packets: 1000,
  rate_limit_window_ms: 1000,

  # Limit packet size to prevent memory exhaustion
  max_packet_size: 8192,

  # Use reasonable connection limits
  num_connections: 10_000,

  # Configure socket buffers
  transport_options: [
    recbuf: 262_144,  # 256KB receive buffer
    sndbuf: 262_144   # 256KB send buffer
  ]
])
```

### Security Considerations

1. **Rate Limiting**: Always enable rate limiting for public services
2. **Packet Size Limits**: Set appropriate `max_packet_size` limits
3. **Connection Limits**: Monitor and adjust `num_connections` based on resources
4. **Network Access**: Use firewall rules to restrict access when possible
5. **Monitoring**: Set up alerts for rate limiting events

### Monitoring Security Events

```elixir
:telemetry.attach_many(
  "security-monitor",
  [
    [:abyss, :listener, :rate_limit_exceeded],
    [:abyss, :listener, :packet_too_large]
  ],
  &handle_security_event/4,
  %{}
)

defp handle_security_event(event, measurements, metadata, config) do
  case event do
    [:abyss, :listener, :rate_limit_exceeded] ->
      Logger.warn("Rate limit exceeded from #{metadata.remote_address}")

    [:abyss, :listener, :packet_too_large] ->
      Logger.warn("Oversized packet from #{metadata.remote_address}: #{metadata.packet_size} bytes")
  end
end
```

## Examples

### Echo Server

```shell
# Run echo server with trace logging
mix run --no-halt -e 'Code.require_file("example/echo.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: Echo, port: 1234); Process.sleep(:infinity)'

# Test with netcat
echo "Hello, UDP" | nc -4 -u -w1 127.0.0.1 1234
```

### DNS Server

```shell
# DNS forwarder
mix run --no-halt -e 'Code.require_file("example/dns_forwarder.ex"); Abyss.start_link(handler_module: HandleDNS, port: 53); Process.sleep(:infinity)'

# DNS recursive resolver
mix run --no-halt -e 'Code.require_file("example/dns_recursive.ex"); Abyss.start_link(handler_module: HandleDNS, port: 53); Process.sleep(:infinity)'
```

### Broadcast Services

```shell
# DHCP listener
mix run --no-halt -e 'Code.require_file("example/dump_dhcp.ex"); Abyss.start_link(handler_module: DumpDHCP, port: 67, broadcast: true, transport_options: [broadcast: true, multicast_if: {255, 255, 255, 255}]); Process.sleep(:infinity)'

# mDNS listener
mix run --no-halt -e 'Code.require_file("example/dump_mdns.ex"); Abyss.start_link(handler_module: DumpMDNS, port: 5353, broadcast: true, transport_options: [broadcast: true, multicast_if: {224, 0, 0, 251}]); Process.sleep(:infinity)'
```

## Architecture

Abyss implements a hierarchical supervision tree:

```
Abyss (main supervisor)
├── Abyss.RateLimiter (if enabled)
├── Abyss.ListenerPool (supervisor)
│   ├── Abyss.Listener (listener process 1)
│   ├── Abyss.Listener (listener process 2)
│   └── ... (up to num_listeners processes)
├── DynamicSupervisor (connection supervisor)
│   ├── Handler process 1 (per UDP packet)
│   ├── Handler process 2 (per UDP packet)
│   └── ... (up to num_connections processes)
├── Task (activator - starts listeners)
└── Abyss.ShutdownListener (coordinates graceful shutdown)
```

### Request Flow

1. **Listener Pool**: Manages multiple listener processes for load distribution
2. **Listener**: Waits for UDP packets on the bound port
3. **Connection**: Creates handler processes for incoming packets
4. **Handler**: Processes packet data using user-defined logic
5. **Transport**: Handles low-level UDP socket operations

### Supervision Strategy

- **Rest for One**: If a listener crashes, other listeners continue
- **Dynamic Supervisor**: Handler processes are isolated
- **Graceful Shutdown**: Coordinated termination with timeouts

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Open a Pull Request

### Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Run tests with coverage
mix test --cover

# Format code
mix format

# Run dialyzer
mix dialyzer

# Run credo
mix credo

# Generate documentation
mix docs
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.
# Updated at Wed Oct 15 13:02:51 CST 2025
