# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Abyss is a pure Elixir UDP server library that provides a modern, high-performance foundation for building UDP-based services like DNS servers, DHCP servers, or custom UDP applications. It implements a supervisor-based architecture with connection pooling, pluggable transport modules, and built-in security features including rate limiting and packet size validation.

**Important**: Abyss is part of the Yellow Dog umbrella project and uses shared build paths configured in mix.exs:
- `build_path: "../../_build"`
- `deps_path: "../../deps"`
- `lockfile: "../../mix.lock"`
- `config_path: "../../config/config.exs"`

This means dependencies and build artifacts are shared across the entire Yellow Dog project.

## Key Architecture

- **Core Module**: `Abyss` - Main API entry point
- **Server**: `Abyss.Server` - Supervisor that manages listener pools and connection supervisors
- **Server Config**: `Abyss.ServerConfig` - Configuration management and validation with security options
- **Transport**: `Abyss.Transport` - Behaviour for UDP transport layer
  - `Abyss.Transport.UDP` - Main UDP transport module
  - `Abyss.Transport.UDP.Core` - Core UDP socket operations
  - `Abyss.Transport.UDP.Unicast` - Unicast-specific implementation
  - `Abyss.Transport.UDP.Broadcast` - Broadcast/multicast-specific implementation
- **Listener Pool**: `Abyss.ListenerPool` - Manages UDP listener processes with supervisor strategies
- **Listener Pool Scaler**: `Abyss.ListenerPoolScaler` - Dynamic scaling of listener pool based on load
- **Connection Handling**: `Abyss.Connection` - Handles individual UDP connections/clients via DynamicSupervisor with non-blocking retry logic
- **Handler**: `Abyss.Handler` - Behaviour for implementing custom request/response logic
- **Rate Limiter**: `Abyss.RateLimiter` - Token bucket rate limiting for DoS protection (GenServer-based)
- **Telemetry**: `Abyss.Telemetry` - Metrics and monitoring via :telemetry
- **Logger**: `Abyss.Logger` - Structured logging with different levels

## Development Commands

### Build & Test
```bash
# Install dependencies (from umbrella root or app directory)
mix deps.get

# Run tests (includes coverage by default)
mix test

# Run specific test types
mix test.unit              # Unit tests only
mix test.integration       # Integration tests only
mix test.all              # All tests including slow ones

# Run tests with coverage explicitly
mix test --cover

# Run specific test file
mix test test/abyss/server_test.exs

# Run tests matching a pattern
mix test --only unit

# Format code
mix format

# Check code formatting without modifying files
mix format --check-formatted

# Run dialyzer for type checking
mix dialyzer

# Run credo for code quality
mix credo

# Run credo with strict checks (used in CI)
mix credo --strict

# Run linting (combines credo and dialyzer)
mix lint

# Generate documentation
mix docs

# Publish package
mix publish  # Runs format + hex.publish

# Full CI pipeline check
mix ci  # Runs format check, credo strict, and integration tests
```

### Working in Umbrella Context
Since Abyss is part of the Yellow Dog umbrella project:

```bash
# From umbrella root - affects all apps
cd /path/to/yellow-dog
mix test                   # Run all tests across all apps
mix format                 # Format all apps

# From abyss directory - affects only abyss
cd apps/abyss
mix test                   # Run only abyss tests
mix format                 # Format only abyss code

# Clean shared build artifacts (from umbrella root)
mix clean
```

### Running Examples

```bash
# Basic echo server (using Echo module from example/echo.ex)
mix run --no-halt -e 'Code.require_file("example/echo.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: Echo, port: 1234); Process.sleep(:infinity)'

# DNS forwarder
mix run --no-halt -e 'Code.require_file("example/dns_forwarder.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: HandleDNS, port: 53); Process.sleep(:infinity)'

# DNS recursive resolver
mix run --no-halt -e 'Code.require_file("example/dns_recursive.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: HandleDNS, port: 53); Process.sleep(:infinity)'

# DHCP listener
mix run --no-halt -e 'Code.require_file("example/dump_dhcp.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: DumpDHCP, port: 67, broadcast: true, transport_options: [broadcast: true, multicast_if: {255, 255, 255, 255}]); Process.sleep(:infinity)'

# mDNS listener
mix run --no-halt -e 'Code.require_file("example/dump_mdns.ex"); Abyss.Logger.attach_logger(:trace); Abyss.start_link(handler_module: DumpMDNS, port: 5353, broadcast: true, transport_options: [broadcast: true, multicast_if: {224, 0, 0, 251}]); Process.sleep(:infinity)'
```

### Testing with netcat
```bash
# Test echo server
echo "Hello, UDP" | nc -4 -u -w1 127.0.0.1 1234

# Continuous testing
while true; do echo "Hello, UDP $(date +%T)" | nc -4 -u -w1 127.0.0.1 1234; done
```

## Core Components

### Handler Implementation
Create custom handlers by implementing the `Abyss.Handler` behaviour:

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
end
```

### Configuration Options
Key options when starting Abyss:
- `port`: UDP port to listen on
- `handler_module`: Your handler module (required)
- `num_listeners`: Number of listener processes (default: 100)
- `num_connections`: Max concurrent connections (default: 16_384)
- `broadcast`: Enable broadcast mode for DHCP/mDNS (default: false)
- `transport_options`: Additional UDP socket options
- `read_timeout`: Connection read timeout (default: 60_000ms)
- `shutdown_timeout`: Graceful shutdown timeout (default: 15_000ms)
- `rate_limit_enabled`: Enable rate limiting for DoS protection (default: false)
- `rate_limit_max_packets`: Max packets per rate limit window (default: 1000)
- `rate_limit_window_ms`: Rate limit window in milliseconds (default: 1000)
- `max_packet_size`: Maximum allowed packet size in bytes (default: 8192)

## Telemetry and Monitoring

### Built-in Metrics
Abyss provides comprehensive real-time metrics through the `Abyss.Telemetry` module:

#### Connection Metrics
- **`connections_active`**: Currently active connections
- **`connections_total`**: Total connections since server start
- **`accepts_total`**: Total accepted connections
- **`responses_total`**: Total responses sent

#### Rate Metrics
- **`accepts_per_second`**: Current accepts per second (1-second rolling window)
- **`responses_per_second`**: Current responses per second (1-second rolling window)

#### Response Time Tracking
- **`[:abyss, :metrics, :response_time]`**: Telemetry event for each response with timing in milliseconds

### Using Telemetry Metrics

```elixir
# Get current metrics snapshot
metrics = Abyss.Telemetry.get_metrics()
# => %{
#   connections_active: 15,
#   connections_total: 1250,
#   accepts_total: 1250,
#   responses_total: 1198,
#   accepts_per_second: 25,
#   responses_per_second: 23
# }

# Reset all metrics
Abyss.Telemetry.reset_metrics()

# Listen for response time events
:telemetry.attach_many(
  "response-time-monitor",
  [[:abyss, :metrics, :response_time]],
  fn [:abyss, :metrics, :response_time], measurements, _metadata, _config ->
    # Handle response time data
    IO.inspect(measurements.response_time)
  end,
  %{}
)
```

### Telemetry Events
Abyss emits comprehensive telemetry events for monitoring:

#### Connection Lifecycle
- `[:abyss, :listener, :start/stop]` - Listener process lifecycle
- `[:abyss, :connection, :start/stop]` - Connection handling lifecycle
- `[:abyss, :connection, :ready]` - Connection ready for processing
- `[:abyss, :connection, :send/recv]` - Data transmission events

#### Security Events
- `[:abyss, :listener, :rate_limit_exceeded]` - Rate limit violations
- `[:abyss, :listener, :packet_too_large]` - Oversized packets rejected

#### Performance Events
- `[:abyss, :acceptor, :spawn_error]` - Connection spawn failures
- `[:abyss, :metrics, :response_time]` - Response timing measurements

### Monitoring with Logger
Attach structured logging for real-time monitoring:

```elixir
# Enable debug logging for detailed telemetry
Abyss.Logger.attach_logger(:debug)

# Enable trace logging for comprehensive monitoring
Abyss.Logger.attach_logger(:trace)
```

## Security Features

### Rate Limiting
Abyss includes a token bucket rate limiter (`Abyss.RateLimiter`) for DoS protection:
- Per-IP rate limiting using token bucket algorithm
- Configurable packet limits and time windows
- Automatic cleanup of expired rate limit buckets
- Telemetry events for rate limit violations

### Packet Size Validation
Incoming packets are validated against `max_packet_size` to prevent memory exhaustion attacks.

## Project Structure

```
lib/
├── abyss.ex              # Main API entry point
├── abyss/
│   ├── server.ex         # Main supervisor managing all components
│   ├── server_config.ex  # Configuration validation and defaults
│   ├── listener_pool.ex  # Pool of listener processes (supervisor)
│   ├── listener_pool_scaler.ex # Dynamic scaling of listener pool
│   ├── listener.ex       # Individual listener process with security checks
│   ├── connection.ex     # Connection lifecycle management with non-blocking retry
│   ├── handler.ex        # Handler behaviour and GenServer implementation
│   ├── rate_limiter.ex   # Token bucket rate limiting for DoS protection
│   ├── transport.ex      # Transport behaviour definition
│   ├── transport/
│   │   ├── udp.ex        # Main UDP transport module
│   │   └── udp/
│   │       ├── core.ex       # Core UDP socket operations
│   │       ├── unicast.ex    # Unicast implementation
│   │       └── broadcast.ex  # Broadcast/multicast implementation
│   ├── telemetry.ex      # Telemetry event handling and metrics
│   ├── logger.ex         # Structured logging utilities
│   └── shutdown_listener.ex # Graceful shutdown coordination
example/                  # Usage examples and demos
├── echo.ex              # Basic echo server
├── dns_forwarder.ex     # DNS forwarding to upstream servers
├── dns_recursive.ex     # DNS recursive resolver
├── dump_dhcp.ex         # DHCP packet monitoring
├── dump_mdns.ex         # mDNS packet monitoring
└── dump.ex              # Generic packet dumping
test/
├── abyss/               # Unit tests for core modules
│   ├── server_test.exs
│   ├── server_config_test.exs
│   ├── listener_pool_test.exs
│   ├── listener_pool_scaler_test.exs
│   ├── listener_test.exs
│   ├── listener_comprehensive_test.exs
│   ├── listener_rate_limiting_test.exs
│   ├── connection_test.exs
│   ├── handler_test.exs
│   ├── rate_limiter_test.exs
│   ├── telemetry_test.exs
│   ├── telemetry_metrics_test.exs
│   ├── telemetry_integration_test.exs
│   ├── logger_test.exs
│   ├── transport_udp_comprehensive_test.exs
│   └── transport/
│       ├── udp_test.exs
│       └── udp/
│           ├── unicast_test.exs
│           └── broadcast_test.exs
├── integration/         # Integration tests
│   └── echo_test.exs
├── support/             # Test utilities and helpers
└── abyss_test.exs       # Main API tests
```

## Dependencies

- **Core**: Elixir ~> 1.13
- **Runtime**:
  - `telemetry` (~> 1.0) - Metrics and monitoring
  - `telemetry_metrics` (~> 1.0) - Telemetry metric aggregation
- **Development & Testing**:
  - `dialyxir` (~> 1.0) - Static type analysis via Dialyzer
  - `credo` (~> 1.5) - Code quality and style analysis
  - `ex_doc` (>= 0.0.0) - Documentation generation
  - `machete` (>= 0.0.0) - Test utilities and assertions
  - `mox` (~> 1.0) - Mocks and stubs for testing

**Note**: Dependencies are managed at the umbrella level and shared across all Yellow Dog applications.

## Testing Strategy

### Test Organization
- **Unit tests**: Test individual modules in `test/abyss/`
- **Integration tests**: Test end-to-end functionality in `test/integration/`
- **Test support**: Common test utilities in `test/support/`

### Test Execution
```bash
# Run all tests with coverage (default behavior)
mix test

# Run only fast unit tests
mix test.unit

# Run integration tests (may require network access)
mix test.integration

# Run all tests including slow ones
mix test.all

# Run specific test file
mix test test/abyss/server_test.exs

# Run tests matching a pattern
mix test --only unit
```

### Test Coverage
- Target coverage threshold: 40% (configured in mix.exs)
- Current coverage: ~60% (improved from 39.83%)
- Coverage reports generated automatically with `mix test`
- Test modules excluded from coverage: `Abyss.Test.*`

## Architecture Deep Dive

### Supervisor Tree
```
Abyss (main supervisor)
├── Abyss.RateLimiter (if enabled) - Token bucket rate limiting
├── Abyss.ListenerPool (supervisor)
│   ├── Abyss.Listener (listener process 1)
│   ├── Abyss.Listener (listener process 2)
│   └── ... (up to num_listeners processes, dynamically scalable)
├── Abyss.ListenerPoolScaler (monitors and scales listener pool)
├── DynamicSupervisor (connection supervisor)
│   ├── Handler process 1 (per UDP packet)
│   ├── Handler process 2 (per UDP packet)
│   └── ... (up to num_connections processes)
├── Task (activator - starts listeners)
└── Abyss.ShutdownListener (coordinates graceful shutdown)
```

### Request Flow with Security
1. **Listener Pool**: Manages multiple listener processes for load distribution
2. **Listener**: Waits for UDP packets, applies rate limiting and packet size validation
3. **Connection**: Creates handler processes for valid packets with non-blocking retry logic
4. **Handler**: Processes packet data using user-defined logic
5. **Transport**: Handles low-level UDP socket operations
6. **Rate Limiter**: Enforces per-IP rate limits using token bucket algorithm

### Broadcast Mode
When `broadcast: true` is set:
- Only one listener process is created (regardless of `num_listeners`)
- Uses `Abyss.Transport.UDP.Broadcast` for broadcast/multicast handling
- Packets are processed in broadcast mode (useful for DHCP/mDNS)
- Handler processes terminate after processing each packet

### UDP Transport Architecture
The UDP transport layer is modular and organized into specialized modules:

1. **`Abyss.Transport.UDP`**: Main transport module that delegates to appropriate implementations
2. **`Abyss.Transport.UDP.Core`**: Core UDP socket operations shared by all implementations
3. **`Abyss.Transport.UDP.Unicast`**: Standard unicast UDP communication
4. **`Abyss.Transport.UDP.Broadcast`**: Broadcast and multicast UDP communication with special socket options

This modular design allows for clean separation of concerns and easier testing/maintenance of different UDP modes.

### Non-Blocking Connection Retry
Connection retry logic uses `Process.send_after/3` instead of blocking `Process.sleep/1`:
- Prevents listener process blocking during connection retries
- Configurable retry count and wait times via `max_connections_retry_count` and `max_connections_retry_wait`
- Graceful degradation when connection supervisor is at capacity

### Telemetry Events
Abyss emits comprehensive telemetry events for monitoring:
- `[:abyss, :listener, :start/stop/ready/waiting/receiving]`
- `[:abyss, :connection, :start/stop/ready/send/recv]`
- `[:abyss, :acceptor, :start/stop/spawn_error]`
- `[:abyss, :listener, :rate_limit_exceeded]` - Security event
- `[:abyss, :listener, :packet_too_large]` - Security event

Use `Abyss.Logger.attach_logger(:level)` to enable logging at different levels.

## Key Implementation Details

### Rate Limiting Algorithm
The rate limiter uses a token bucket algorithm:
- Each IP address has a bucket with configurable token capacity
- Tokens are refilled at a constant rate based on time elapsed
- Packets consume tokens; requests are rejected when bucket is empty
- Buckets are automatically cleaned up after periods of inactivity

### Connection Management
- Non-blocking retry logic prevents listener starvation
- DynamicSupervisor manages handler process lifecycle
- Configurable connection limits prevent resource exhaustion
- Graceful shutdown ensures proper resource cleanup

### Error Handling Patterns
- Security violations emit telemetry events but don't crash processes
- Connection failures trigger non-blocking retries
- Handler process isolation prevents cascading failures
- Comprehensive logging for debugging and monitoring

## Common Development Tasks

### 1. Adding New Transport Modules
Implement the `Abyss.Transport` behaviour:
```elixir
defmodule Abyss.Transport.MyTransport do
  @behaviour Abyss.Transport

  @impl true
  def listen(port, options) do
    # Implementation for listening on given port
  end

  # Implement all required callbacks...
end
```

### 2. Creating Custom Handlers
Use the `Abyss.Handler` behaviour:
```elixir
defmodule MyHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Your custom logic here
    {:continue, state}
  end

  # Optional callbacks for error handling, timeouts, etc.
end
```

### 3. Running Examples for Development
```bash
# Start with trace logging for debugging
mix run --no-halt -e 'Abyss.Logger.attach_logger(:debug); Code.require_file("example/echo.ex"); Abyss.start_link(handler_module: Echo, port: 1234); Process.sleep(:infinity)'
```

### 4. Development Workflow
```bash
# 1. Make changes
# 2. Run formatter
mix format

# 3. Run type checker
mix dialyzer

# 4. Run code quality checks
mix credo --strict

# 5. Run tests
mix test

# 6. Full CI check
mix ci
```

### 5. Documentation Updates
- Update module docs with `@moduledoc`
- Run `mix docs` to generate HTML documentation
- Update README.md for user-facing changes

### 6. Publishing Releases
```bash
# Ensure all checks pass
mix ci

# Bump version in mix.exs if needed
# Update CHANGELOG.md

# Publish to Hex
mix publish
```

## Debugging and Development Tips

### Common Issues
1. **Port already in use**: Ensure port is not bound by another process
2. **Permission denied**: Avoid privileged ports (< 1024) or run with sudo
3. **Handler crashes**: Check that handler modules implement required callbacks
4. **Connection limits**: Adjust `num_connections` if hitting max connections
5. **Rate limiting**: Monitor telemetry events for rate limit violations
6. **Packet size**: Check `max_packet_size` configuration if packets are rejected

### Debugging Commands
```bash
# Start with debug logging
mix run --no-halt -e 'Abyss.Logger.attach_logger(:debug); # your server code'

# Check listener pool status
# In IEx: Abyss.ListenerPool.listener_pids(pid)

# Check connection supervisor status
# In IEx: Abyss.Server.connection_sup_pid(pid)

# Monitor rate limiter statistics
# In IEx: Abyss.RateLimiter.get_stats()
```

### Performance Tuning
- **num_listeners**: Increase for high-throughput scenarios (default: 100)
- **num_connections**: Set appropriate limits for your use case
- **rate_limit_max_packets**: Adjust based on expected traffic patterns
- **max_packet_size**: Set based on protocol requirements
- **read_timeout**: Adjust based on expected protocol timing
- **transport_options**: Tune UDP buffer sizes as needed

## Working with Yellow Dog Umbrella

### Umbrella-Specific Considerations

Since Abyss is part of the Yellow Dog umbrella project:

1. **Shared Dependencies**: All dependencies are resolved at the umbrella level in `../../deps/`
2. **Shared Build Artifacts**: Build outputs go to `../../_build/`
3. **Shared Lock File**: The `../../mix.lock` is used for dependency locking
4. **Shared Configuration**: Application config in `../../config/config.exs`

### Cross-App Dependencies

Abyss is used by several Yellow Dog applications:
- `yellow_dog_dns` - DNS server using Abyss UDP transport
- `yellow_dog_dhcpv4` - DHCPv4 server using Abyss
- `yellow_dog_dhcpv6` - DHCPv6 server using Abyss
- `yellow_dog_mdns` - mDNS responder using Abyss

When making changes to Abyss:
1. Consider impact on dependent applications
2. Run tests across the entire umbrella: `cd ../.. && mix test`
3. Check that examples still work in dependent apps

### Development Workflow

```bash
# Work on Abyss in isolation
cd apps/abyss
mix test
mix format

# Test impact on entire umbrella
cd ../..
mix test                  # Run all tests
mix format                # Format all apps

# Test specific dependent app
cd apps/yellow_dog_dns
mix test
```

## Key Patterns

### Handler State Management
```elixir
defmodule MyHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Access socket via state.socket
    # Store custom state in state map
    new_state = Map.put(state, :last_client, {ip, port})
    {:continue, new_state}
  end
end
```

### Error Handling
```elixir
@impl true
def handle_error(reason, state) do
  Logger.error("Handler error: #{inspect(reason)}")
  # Cleanup resources
end
```

### Timeout Handling
```elixir
@impl true
def handle_data({ip, port, data}, state) do
  # Set custom timeout for next packet
  {:continue, state, 30_000}  # 30 second timeout
end

@impl true
def handle_timeout(state) do
  Logger.warn("Connection timed out")
  # Timeout cleanup logic
end
```

### Security Monitoring
```elixir
# Monitor security events via telemetry
:telemetry.attach_many(
  "security-monitor",
  [
    [:abyss, :listener, :rate_limit_exceeded],
    [:abyss, :listener, :packet_too_large]
  ],
  &handle_security_event/4,
  %{}
)
```