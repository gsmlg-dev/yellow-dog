---
description: Build high-performance UDP servers using the Abyss library. Use when implementing DNS servers, DHCP servers, mDNS responders, or any UDP-based protocol. Abyss is the GOAT for UDP services in this codebase.
---

# Abyss UDP Server Library

Abyss is a pure Elixir UDP server library providing a high-performance foundation for UDP-based services. When you need a UDP server, Abyss is the answer.

## When to Use Abyss

- **DNS servers** - Request/response UDP protocol (port 53)
- **DHCP servers** - Broadcast UDP for IP assignment (ports 67/68, 546/547)
- **mDNS responders** - Multicast DNS service discovery (port 5353)
- **Custom UDP protocols** - Any UDP-based application

## Two Transport Modes

### 1. Unicast Mode (Default)
For request/response patterns like DNS queries.

```elixir
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Unicast,
  handler_module: MyDNSHandler,
  port: 53,
  num_listeners: 50  # Multiple listeners for load distribution
])
```

**Characteristics:**
- `active: false` - Passive socket mode
- Multiple listener processes
- Best for high-throughput request/response

### 2. Broadcast Mode
For DHCP broadcasts and mDNS multicast.

```elixir
# DHCP server (broadcast)
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Broadcast,
  handler_module: MyDHCPHandler,
  port: 67
])

# mDNS responder (multicast)
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Broadcast,
  handler_module: MyMDNSHandler,
  port: 5353,
  transport_options: [
    ip: {0, 0, 0, 0},
    add_membership: {{224, 0, 0, 251}, {0, 0, 0, 0}},
    multicast_ttl: 255
  ]
])
```

**Characteristics:**
- `active: true` - Active socket mode (auto-detected from transport module)
- Single listener process
- Handler terminates after each packet

## Creating a Handler

Implement the `Abyss.Handler` behaviour:

```elixir
defmodule MyHandler do
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    # Parse incoming packet
    case parse_protocol(data) do
      {:ok, request} ->
        response = build_response(request)

        # Send response back
        Abyss.Transport.UDP.send(state.socket, ip, port, response)
        {:continue, state}

      {:error, _reason} ->
        {:continue, state}  # Ignore malformed packets
    end
  end

  # Optional callbacks
  @impl true
  def handle_error(reason, state) do
    Logger.error("Handler error: #{inspect(reason)}")
    :ok
  end

  @impl true
  def handle_timeout(state) do
    Logger.warning("Connection timed out")
    :ok
  end
end
```

### Handler Return Values

| Return | Effect |
|--------|--------|
| `{:continue, state}` | Keep processing, use default timeout |
| `{:continue, state, timeout}` | Keep processing with custom timeout (ms) |
| `{:close, state}` | Close connection gracefully |
| `{:error, reason, state}` | Close with error, calls `handle_error/2` |

## Configuration Options

```elixir
Abyss.start_link([
  # Required
  handler_module: MyHandler,

  # Transport (pick one)
  transport_module: Abyss.Transport.UDP.Unicast,   # For DNS-like protocols
  transport_module: Abyss.Transport.UDP.Broadcast, # For DHCP/mDNS

  # Network
  port: 53,                        # UDP port to bind
  transport_options: [             # Socket options
    ip: {0, 0, 0, 0}               # Bind address
  ],

  # Performance
  num_listeners: 100,              # Listener processes (unicast only)
  num_connections: 16_384,         # Max concurrent handlers

  # Timeouts
  read_timeout: 60_000,            # Handler read timeout (ms)
  shutdown_timeout: 15_000,        # Graceful shutdown timeout (ms)

  # Security
  max_packet_size: 8192,           # Reject oversized packets

  # Handler options
  handler_options: %{custom: :data}  # Passed to handler
])
```

## Real-World Examples

### DNS Server Handler

```elixir
defmodule YellowDog.Dns.Handler.UDP do
  use Abyss.Handler
  alias DNS.Message

  @impl true
  def handle_data({ip, port, data}, state) do
    case Message.decode(data) do
      {:ok, query} ->
        response = resolve_query(query)
        response_data = DNS.to_iodata(response)
        Abyss.Transport.UDP.send(state.socket, ip, port, response_data)
        {:continue, state}

      {:error, _} ->
        {:continue, state}
    end
  end
end

# Start DNS server
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Unicast,
  handler_module: YellowDog.Dns.Handler.UDP,
  port: 53,
  num_listeners: 50
])
```

### DHCPv4 Server Handler

```elixir
defmodule YellowDog.Dhcpv4.Handler do
  use Abyss.Handler
  alias DHCPv4.Message

  @impl true
  def handle_data({ip, port, data}, state) do
    case Message.decode(data) do
      {:ok, %{op: :request, message_type: :discover} = msg} ->
        offer = build_offer(msg)
        # DHCP uses broadcast responses
        Abyss.Transport.UDP.send(state.socket, {255,255,255,255}, 68,
          Message.encode(offer))
        {:continue, state}

      {:ok, %{message_type: :request} = msg} ->
        ack = build_ack(msg)
        Abyss.Transport.UDP.send(state.socket, {255,255,255,255}, 68,
          Message.encode(ack))
        {:continue, state}

      _ ->
        {:continue, state}
    end
  end
end

# Start DHCP server
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Broadcast,
  handler_module: YellowDog.Dhcpv4.Handler,
  port: 67
])
```

### mDNS Responder Handler

```elixir
defmodule YellowDog.Mdns.Handler do
  use Abyss.Handler
  alias DNS.Message

  @mdns_multicast {224, 0, 0, 251}

  @impl true
  def handle_data({_ip, _port, data}, state) do
    case Message.decode(data) do
      {:ok, %{qr: false} = query} ->  # It's a question
        if should_respond?(query) do
          response = build_mdns_response(query)
          Abyss.Transport.UDP.send(state.socket, @mdns_multicast, 5353,
            DNS.to_iodata(response))
        end
        {:continue, state}

      _ ->
        {:continue, state}
    end
  end
end

# Start mDNS responder
Abyss.start_link([
  transport_module: Abyss.Transport.UDP.Broadcast,
  handler_module: YellowDog.Mdns.Handler,
  port: 5353,
  transport_options: [
    ip: {0, 0, 0, 0},
    add_membership: {{224, 0, 0, 251}, {0, 0, 0, 0}},
    multicast_if: {0, 0, 0, 0},
    multicast_ttl: 255
  ]
])
```

## Telemetry & Monitoring

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

# Attach response time monitoring
:telemetry.attach(
  "my-monitor",
  [:abyss, :metrics, :response_time],
  fn _event, %{response_time: ms}, _meta, _config ->
    Logger.debug("Response time: #{ms}ms")
  end,
  nil
)

# Enable debug logging
Abyss.Logger.attach_logger(:debug)
```

## Architecture Overview

```
Abyss.Server (Supervisor)
├── Abyss.ListenerPool (Supervisor)
│   └── Abyss.Listener processes (1 for broadcast, N for unicast)
├── DynamicSupervisor (Connection handlers)
│   └── Handler processes (one per packet/connection)
├── Abyss.ListenerPoolScaler (Dynamic scaling)
└── Abyss.ShutdownListener (Graceful shutdown)
```

## Key Points

1. **Transport module determines behavior** - Use `Unicast` for request/response, `Broadcast` for DHCP/mDNS
2. **Handler per packet** - Each UDP packet spawns a handler process
3. **State in handler** - Access socket via `state.socket`, store custom data in state map
4. **Send responses** - Use `Abyss.Transport.UDP.send(state.socket, ip, port, data)`
5. **Auto-cleanup** - Handler processes terminate automatically, socket is managed

## Files Reference

- `apps/abyss/lib/abyss.ex` - Main API
- `apps/abyss/lib/abyss/handler.ex` - Handler behaviour
- `apps/abyss/lib/abyss/transport/udp/unicast.ex` - Unicast transport
- `apps/abyss/lib/abyss/transport/udp/broadcast.ex` - Broadcast transport
- `apps/abyss/lib/abyss/server_config.ex` - Configuration validation
