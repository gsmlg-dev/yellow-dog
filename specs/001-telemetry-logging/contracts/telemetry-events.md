# Telemetry Events Contract

**Feature Branch**: `001-telemetry-logging`
**Date**: 2025-12-22

## Overview

This document defines the contract for telemetry events in the YellowDog system. All protocol applications MUST emit these events instead of using direct Logger calls.

---

## Event Format

All events follow the standard `:telemetry` format:

```elixir
:telemetry.execute(event_name, measurements, metadata)
```

Where:
- `event_name` - List of atoms: `[:yellow_dog, <service>, <resource>, <action>]`
- `measurements` - Map with numeric values (counts, durations)
- `metadata` - Map with contextual data (strings, tuples, atoms)

---

## DNS Service Events

### Query Received

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :received],
  %{count: 1},
  %{
    query_name: "example.com",
    query_type: :a,
    query_class: :in,
    client_ip: {192, 168, 1, 100},
    client_port: 54321,
    transport: :udp
  }
)
```

### Query Completed

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :completed],
  %{
    count: 1,
    duration_us: 1523,
    answer_count: 2
  },
  %{
    query_name: "example.com",
    query_type: :a,
    response_code: :noerror,
    source: :cache,
    client_ip: {192, 168, 1, 100}
  }
)
```

### Query Error

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :query, :error],
  %{count: 1},
  %{
    query_name: "invalid.example",
    query_type: :a,
    error: :nxdomain,
    client_ip: {192, 168, 1, 100}
  }
)
```

### Cache Hit/Miss

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :cache, :hit],
  %{count: 1},
  %{query_name: "cached.example.com", query_type: :a, ttl: 3600}
)

:telemetry.execute(
  [:yellow_dog, :dns, :cache, :miss],
  %{count: 1},
  %{query_name: "new.example.com", query_type: :a}
)
```

### Zone Loaded

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :zone, :loaded],
  %{count: 1, record_count: 150, load_time_ms: 12.5},
  %{zone_name: "example.com", file_path: "/etc/zones/example.com.zone"}
)
```

### Server Started/Stopped

```elixir
:telemetry.execute(
  [:yellow_dog, :dns, :server, :started],
  %{count: 1},
  %{port: 53, listen_address: {0, 0, 0, 0}, transport: :udp}
)

:telemetry.execute(
  [:yellow_dog, :dns, :server, :stopped],
  %{count: 1},
  %{port: 53, reason: :shutdown}
)
```

---

## DHCPv4 Service Events

### Lease Requested

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :requested],
  %{count: 1},
  %{
    message_type: :discover,
    client_mac: "AA:BB:CC:DD:EE:FF",
    transaction_id: 0x12345678,
    requested_ip: nil,
    hostname: "client-pc"
  }
)
```

### Lease Granted

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :granted],
  %{count: 1, lease_time: 86400},
  %{
    ip_address: {192, 168, 1, 100},
    client_mac: "AA:BB:CC:DD:EE:FF",
    pool_name: "default",
    message_type: :ack
  }
)
```

### Lease Released

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :released],
  %{count: 1},
  %{
    ip_address: {192, 168, 1, 100},
    client_mac: "AA:BB:CC:DD:EE:FF",
    reason: :client_release
  }
)
```

### Lease Expired

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :lease, :expired],
  %{count: 5},
  %{
    ip_addresses: [{192, 168, 1, 100}, {192, 168, 1, 101}],
    pool_name: "default"
  }
)
```

### Server Started

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv4, :server, :started],
  %{count: 1},
  %{
    port: 67,
    listen_address: {0, 0, 0, 0},
    pool_count: 2
  }
)
```

---

## DHCPv6 Service Events

### Lease Requested

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv6, :lease, :requested],
  %{count: 1},
  %{
    message_type: :solicit,
    duid: <<0, 1, 0, 1, ...>>,
    iaid: 1,
    client_ip: {0xFE80, 0, 0, 0, 0, 0, 0, 1}
  }
)
```

### Lease Granted

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv6, :lease, :granted],
  %{
    count: 1,
    preferred_lifetime: 3600,
    valid_lifetime: 7200
  },
  %{
    ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
    duid: <<0, 1, 0, 1, ...>>,
    iaid: 1,
    message_type: :reply
  }
)
```

### Server Started

```elixir
:telemetry.execute(
  [:yellow_dog, :dhcpv6, :server, :started],
  %{count: 1},
  %{
    port: 547,
    listen_address: {0, 0, 0, 0, 0, 0, 0, 0},
    pool_count: 1
  }
)
```

---

## mDNS Service Events

### Service Registered

```elixir
:telemetry.execute(
  [:yellow_dog, :mdns, :service, :registered],
  %{count: 1},
  %{
    service_name: "My Web Server",
    service_type: "_http._tcp",
    port: 8080,
    txt_records: %{"path" => "/", "version" => "1.0"},
    hostname: "myserver.local"
  }
)
```

### Service Unregistered

```elixir
:telemetry.execute(
  [:yellow_dog, :mdns, :service, :unregistered],
  %{count: 1},
  %{
    service_name: "My Web Server",
    service_type: "_http._tcp",
    reason: :manual
  }
)
```

### Query Received

```elixir
:telemetry.execute(
  [:yellow_dog, :mdns, :query, :received],
  %{count: 1},
  %{
    query_name: "_http._tcp.local",
    query_type: :ptr,
    source_ip: {192, 168, 1, 50},
    is_unicast: false
  }
)
```

### Response Sent

```elixir
:telemetry.execute(
  [:yellow_dog, :mdns, :response, :sent],
  %{count: 1, record_count: 4},
  %{
    response_type: :multicast,
    query_name: "_http._tcp.local",
    destination_ip: nil
  }
)
```

### Server Started

```elixir
:telemetry.execute(
  [:yellow_dog, :mdns, :server, :started],
  %{count: 1},
  %{
    port: 5353,
    multicast_address: {224, 0, 0, 251},
    mode: :hybrid
  }
)
```

---

## Handler Interface

Handlers MUST implement the following signature:

```elixir
@callback handle_event(
  event :: [atom()],
  measurements :: map(),
  metadata :: map(),
  config :: map()
) :: :ok
```

### Example Handler

```elixir
defmodule YellowDog.Telemetry.LoggerHandlers do
  require Logger

  def handle_dns_event([:yellow_dog, :dns, :query, action], measurements, metadata, config) do
    try do
      Logger.log(config.level, fn ->
        format_dns_event(action, measurements, metadata)
      end)
    rescue
      _ -> :ok
    end
  end

  defp format_dns_event(:received, _measurements, metadata) do
    "DNS query: #{metadata.query_name} (#{metadata.query_type}) from #{format_ip(metadata.client_ip)}"
  end

  defp format_dns_event(:completed, measurements, metadata) do
    "DNS response: #{metadata.query_name} -> #{metadata.response_code} (#{measurements.duration_us}μs, #{measurements.answer_count} answers)"
  end

  defp format_dns_event(:error, _measurements, metadata) do
    "DNS error: #{metadata.query_name} -> #{metadata.error}"
  end
end
```

---

## Handler Registration

### Attach All Handlers

```elixir
def attach_logger_handlers do
  # DNS events
  :telemetry.attach_many(
    "yellow-dog-dns-logger",
    [
      [:yellow_dog, :dns, :query, :received],
      [:yellow_dog, :dns, :query, :completed],
      [:yellow_dog, :dns, :query, :error],
      [:yellow_dog, :dns, :cache, :hit],
      [:yellow_dog, :dns, :cache, :miss],
      [:yellow_dog, :dns, :zone, :loaded],
      [:yellow_dog, :dns, :server, :started],
      [:yellow_dog, :dns, :server, :stopped]
    ],
    &YellowDog.Telemetry.LoggerHandlers.handle_dns_event/4,
    %{level: :info}
  )

  # Similar for DHCPv4, DHCPv6, mDNS...
  :ok
end
```

### Detach All Handlers

```elixir
def detach_logger_handlers do
  :telemetry.detach("yellow-dog-dns-logger")
  :telemetry.detach("yellow-dog-dhcpv4-logger")
  :telemetry.detach("yellow-dog-dhcpv6-logger")
  :telemetry.detach("yellow-dog-mdns-logger")
  :ok
end
```

---

## Testing Contract

Tests SHOULD attach custom handlers to verify event emission:

```elixir
test "DNS query emits telemetry event" do
  test_pid = self()

  handler = fn event, measurements, metadata, _ ->
    send(test_pid, {:event, event, measurements, metadata})
  end

  :telemetry.attach("test", [:yellow_dog, :dns, :query, :received], handler, nil)

  # Trigger DNS query processing...

  assert_receive {:event, [:yellow_dog, :dns, :query, :received], %{count: 1}, metadata}
  assert metadata.query_name == "example.com"

  :telemetry.detach("test")
end
```
