# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Abyss is a pure Elixir UDP server library for building high-performance UDP-based services (DNS, DHCP, mDNS). Part of the Yellow Dog umbrella project with shared build paths:
- `build_path: "../../_build"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`

## Development Commands

```bash
# Run tests (includes coverage)
mix test

# Test variants
mix test.unit              # Fast unit tests only
mix test.integration       # Integration tests only
mix test.all               # All tests including slow

# Run single test file
mix test test/abyss/server_test.exs

# Code quality
mix format                 # Format code
mix lint                   # credo --strict + dialyzer
mix ci                     # Full CI check (format, credo, integration tests)

# From umbrella root
cd ../.. && mix test       # Test all apps
```

## Architecture

### Supervisor Tree
```
Abyss.Server (main supervisor)
├── Abyss.ListenerPool (supervisor)
│   └── Abyss.Listener (1..num_listeners processes)
├── Abyss.ListenerPoolScaler (dynamic scaling)
├── DynamicSupervisor (connection supervisor)
│   └── Handler processes (per UDP packet)
├── Task (activator - starts listeners)
└── Abyss.ShutdownListener (graceful shutdown)
```

### Core Modules
- **`Abyss`** - Main API entry point (`start_link/1`, `stop/2`)
- **`Abyss.Server`** - Supervisor managing all components
- **`Abyss.ServerConfig`** - Configuration validation and defaults
- **`Abyss.Handler`** - Behaviour for implementing custom packet handlers
- **`Abyss.Listener`** - Individual listener process with packet validation
- **`Abyss.ListenerPool`** - Manages listener processes
- **`Abyss.ListenerPoolScaler`** - Dynamic scaling based on load
- **`Abyss.Connection`** - Handler process lifecycle with non-blocking retry
- **`Abyss.Client`** - Stateless UDP client for outbound operations (send, broadcast, subscribe)
- **`Abyss.Utils`** - Network interface discovery utilities

### Transport Layer
- **`Abyss.Transport`** - Behaviour definition
- **`Abyss.Transport.UDP`** - Main UDP module (delegates to implementations)
- **`Abyss.Transport.UDP.Core`** - Shared socket operations
- **`Abyss.Transport.UDP.Unicast`** - Standard unicast
- **`Abyss.Transport.UDP.Broadcast`** - Broadcast/multicast with special socket options

### Observability
- **`Abyss.Telemetry`** - Metrics (connections_active, accepts_per_second, etc.)
- **`Abyss.Logger`** - Structured logging (`attach_logger(:debug|:trace)`)

## Handler Implementation

```elixir
defmodule MyHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Process packet, send response
    Abyss.Transport.UDP.send(state.socket, ip, port, response)
    {:continue, state}  # or {:close, state}
  end

  # Optional callbacks: handle_timeout/1, handle_error/2, init/1, terminate/2
end
```

## Configuration Options

Key options for `Abyss.start_link/1`:
- `handler_module` (required) - Module implementing `Abyss.Handler`
- `port` - UDP port (default: 4000)
- `num_listeners` - Listener process count (default: 100)
- `num_connections` - Max concurrent handlers (default: 16_384)
- `broadcast` - Enable broadcast mode (default: false)
- `transport_options` - Additional UDP socket options
- `read_timeout` - Connection timeout (default: 60_000ms)
- `max_packet_size` - Max packet size in bytes (default: 8192)

### Broadcast Mode
When `broadcast: true`:
- Single listener (ignores `num_listeners`)
- Uses `Abyss.Transport.UDP.Broadcast`
- Handler terminates after each packet

## Telemetry Events

- `[:abyss, :listener, :start|stop|ready|waiting|receiving]`
- `[:abyss, :connection, :start|stop|ready|send|recv]`
- `[:abyss, :acceptor, :start|stop|spawn_error]`
- `[:abyss, :listener, :packet_too_large]` - Security event
- `[:abyss, :metrics, :response_time]` - Response timing

## Cross-App Dependencies

Abyss is used by:
- `yellow_dog_dns` - DNS server
- `yellow_dog_dhcpv4` - DHCPv4 server
- `yellow_dog_dhcpv6` - DHCPv6 server
- `yellow_dog_mdns` - mDNS responder

When modifying Abyss, test impact on dependent apps: `cd ../.. && mix test`

## Test Organization

- `test/abyss/` - Unit tests for core modules
- `test/integration/` - End-to-end tests (echo_test.exs, client_test.exs)
- `test/support/` - Test helpers
- Coverage threshold: 40% (configured in mix.exs)
