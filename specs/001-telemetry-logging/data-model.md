# Data Model: Telemetry-Based Logging System

**Feature Branch**: `001-telemetry-logging`
**Date**: 2025-12-22

## Overview

This document defines the data structures for telemetry events and their associated metadata. Since this feature primarily deals with telemetry events (not persistent storage), the "data model" consists of event schemas and handler configuration structures.

## Core Entities

### 1. Telemetry Event

A telemetry event consists of three components passed to handlers:

```elixir
@type event_name :: [atom()]           # e.g., [:yellow_dog, :dns, :query, :received]
@type measurements :: map()             # Numeric data (counts, durations)
@type metadata :: map()                 # Contextual data (IDs, strings, structs)
```

**Event Structure**:
```elixir
:telemetry.execute(
  event_name,      # [:yellow_dog, <service>, <resource>, <action>]
  measurements,    # %{count: 1, duration_ms: 15}
  metadata         # %{query_name: "example.com", client_ip: {192,168,1,1}}
)
```

### 2. Handler Configuration

Configuration passed to telemetry handlers:

```elixir
@type handler_config :: %{
  level: :debug | :info | :warning | :error,
  format: :pretty | :json | :minimal,
  service: atom()
}
```

### 3. Logger Handler Registry

Internal tracking of attached handlers for detachment:

```elixir
@handler_ids [
  "yellow-dog-dns-logger",
  "yellow-dog-dhcpv4-logger",
  "yellow-dog-dhcpv6-logger",
  "yellow-dog-mdns-logger",
  "yellow-dog-service-logger"
]
```

---

## Event Schemas by Service

### DNS Events

#### `[:yellow_dog, :dns, :query, :received]`

Emitted when a DNS query is received.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| query_name | String.t() | Domain being queried |
| query_type | atom() | Record type (:a, :aaaa, :mx, etc.) |
| query_class | atom() | Query class (:in, :ch, :hs) |
| client_ip | :inet.ip_address() | Client IP tuple |
| client_port | pos_integer() | Client port |
| transport | :udp \| :tcp | Transport protocol |
| timestamp | DateTime.t() | Query received time |

#### `[:yellow_dog, :dns, :query, :completed]`

Emitted when a DNS query is successfully processed.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| duration_us | integer | Processing time in microseconds |
| answer_count | integer | Number of answers |
| **Metadata** |||
| query_name | String.t() | Domain queried |
| query_type | atom() | Record type |
| response_code | atom() | :noerror, :nxdomain, :servfail, etc. |
| source | atom() | :cache, :authoritative, :recursive |
| client_ip | :inet.ip_address() | Client IP tuple |

#### `[:yellow_dog, :dns, :query, :error]`

Emitted when a DNS query encounters an error.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| query_name | String.t() | Domain queried |
| query_type | atom() | Record type |
| error | atom() \| String.t() | Error reason |
| client_ip | :inet.ip_address() | Client IP tuple |

#### `[:yellow_dog, :dns, :cache, :hit]` / `[:yellow_dog, :dns, :cache, :miss]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| query_name | String.t() | Domain looked up |
| query_type | atom() | Record type |
| ttl | integer \| nil | Remaining TTL (hit only) |

#### `[:yellow_dog, :dns, :zone, :loaded]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| record_count | integer | Records in zone |
| load_time_ms | float | Parse/load duration |
| **Metadata** |||
| zone_name | String.t() | Zone origin |
| file_path | String.t() \| nil | Source file if applicable |

---

### DHCPv4 Events

#### `[:yellow_dog, :dhcpv4, :lease, :requested]`

Emitted when a DHCP DISCOVER or REQUEST is received.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| message_type | :discover \| :request | DHCP message type |
| client_mac | String.t() | MAC address (formatted) |
| transaction_id | integer | DHCP xid |
| requested_ip | :inet.ip4_address() \| nil | Requested IP if present |
| hostname | String.t() \| nil | Client hostname option |

#### `[:yellow_dog, :dhcpv4, :lease, :granted]`

Emitted when a lease is allocated (OFFER sent or ACK sent).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| lease_time | integer | Lease duration in seconds |
| **Metadata** |||
| ip_address | :inet.ip4_address() | Allocated IP |
| client_mac | String.t() | MAC address |
| pool_name | String.t() | Pool used |
| message_type | :offer \| :ack | Response type |

#### `[:yellow_dog, :dhcpv4, :lease, :released]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| ip_address | :inet.ip4_address() | Released IP |
| client_mac | String.t() | MAC address |
| reason | :client_release \| :admin | Release reason |

#### `[:yellow_dog, :dhcpv4, :lease, :expired]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Number of expired leases |
| **Metadata** |||
| ip_addresses | [:inet.ip4_address()] | Expired IPs |
| pool_name | String.t() | Pool name |

#### `[:yellow_dog, :dhcpv4, :server, :started]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| port | integer | Listening port |
| listen_address | :inet.ip4_address() | Bind address |
| pool_count | integer | Number of pools configured |

---

### DHCPv6 Events

#### `[:yellow_dog, :dhcpv6, :lease, :requested]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| message_type | :solicit \| :request \| :renew \| :rebind | DHCPv6 message |
| duid | binary() | Client DUID |
| iaid | integer | IA_NA identifier |
| client_ip | :inet.ip6_address() | Link-local address |

#### `[:yellow_dog, :dhcpv6, :lease, :granted]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| preferred_lifetime | integer | Preferred lifetime |
| valid_lifetime | integer | Valid lifetime |
| **Metadata** |||
| ip_address | :inet.ip6_address() | Allocated IPv6 |
| duid | binary() | Client DUID |
| iaid | integer | IA_NA identifier |
| message_type | :advertise \| :reply | Response type |

#### `[:yellow_dog, :dhcpv6, :lease, :released]` / `[:yellow_dog, :dhcpv6, :lease, :expired]`

Similar structure to DHCPv4 equivalents with IPv6 addresses.

#### `[:yellow_dog, :dhcpv6, :server, :started]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| port | integer | Listening port (typically 547) |
| listen_address | :inet.ip6_address() | Bind address |
| pool_count | integer | Number of pools configured |

---

### mDNS Events

#### `[:yellow_dog, :mdns, :service, :registered]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| service_name | String.t() | Service instance name |
| service_type | String.t() | Service type (e.g., "_http._tcp") |
| port | integer | Service port |
| txt_records | map() | TXT record key-value pairs |
| hostname | String.t() | Host providing service |

#### `[:yellow_dog, :mdns, :service, :unregistered]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| service_name | String.t() | Service instance name |
| service_type | String.t() | Service type |
| reason | atom() | :manual, :ttl_expired, :conflict |

#### `[:yellow_dog, :mdns, :query, :received]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| query_name | String.t() | Queried name |
| query_type | atom() | Record type (PTR, SRV, TXT, A, AAAA) |
| source_ip | :inet.ip_address() | Query source |
| is_unicast | boolean() | Unicast response requested |

#### `[:yellow_dog, :mdns, :response, :sent]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| record_count | integer | Number of records in response |
| **Metadata** |||
| response_type | :multicast \| :unicast | Delivery method |
| query_name | String.t() | Original query |
| destination_ip | :inet.ip_address() \| nil | For unicast |

#### `[:yellow_dog, :mdns, :server, :started]`

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| port | integer | Listening port (typically 5353) |
| multicast_address | :inet.ip_address() | Multicast group |
| mode | :responder \| :monitor \| :hybrid | Operation mode |

---

### Service Lifecycle Events

#### `[:yellow_dog, :service, :started]` / `[:yellow_dog, :service, :stopped]`

Generic service lifecycle events for core application logging.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** |||
| count | integer | Always 1 |
| **Metadata** |||
| service | atom() | :dns, :dhcpv4, :dhcpv6, :mdns |
| pid | pid() \| nil | Service process PID |
| config | map() | Sanitized configuration |

---

## Validation Rules

1. **Event Names**: Must follow `[:yellow_dog, <service>, <resource>, <action>]` format
2. **Measurements**: Must contain at least `count: 1`
3. **Metadata**: Must not contain sensitive data (passwords, tokens)
4. **IP Addresses**: Must be Erlang tuple format, not strings
5. **MAC Addresses**: Must be formatted as "XX:XX:XX:XX:XX:XX"
6. **Timestamps**: Must be DateTime structs, not Unix timestamps

## State Transitions

For lease lifecycle events:

```
                    ┌─────────────┐
                    │   Empty     │
                    └──────┬──────┘
                           │ requested
                           ▼
                    ┌─────────────┐
    ┌──────────────►│  Requested  │
    │               └──────┬──────┘
    │                      │ granted
    │                      ▼
    │               ┌─────────────┐
    │ renew/rebind  │   Active    │◄─────────┐
    │               └──────┬──────┘          │
    │                      │                 │ granted
    │                      ├─────────────────┘
    │                      │
    │          released    │    expired
    │              ┌───────┴───────┐
    │              ▼               ▼
    │       ┌──────────┐    ┌──────────┐
    └───────┤ Released │    │ Expired  │
            └──────────┘    └──────────┘
```
