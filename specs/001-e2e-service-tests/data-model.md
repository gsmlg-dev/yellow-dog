# Data Model: E2E Service Tests

**Feature**: 001-e2e-service-tests
**Date**: 2025-12-15

## Overview

This feature is test infrastructure with no persistent data model. The entities below represent runtime test structures and configuration.

## Entities

### E2ETest.ServiceContext

Runtime context passed to tests via ExUnit setup.

```elixir
%{
  server_pid: pid(),           # PID of started service
  port: pos_integer(),         # Auto-assigned port number
  host: :inet.ip_address(),    # Listen address (default: {127,0,0,1})
  service: atom()              # Service type: :dns | :mdns | :dhcpv4 | :dhcpv6
}
```

**Lifecycle**: Created in `setup`, cleaned up in `on_exit`

### DNS Query/Response

DNS message structure from ex_dns library.

```elixir
# Query
%DNS.Message{
  header: %DNS.Header{
    id: non_neg_integer(),     # Transaction ID
    qr: false,                 # Query (not response)
    opcode: :query,
    rd: boolean()              # Recursion desired
  },
  questions: [%DNS.Question{
    name: String.t(),          # e.g., "example.com"
    type: atom(),              # :A, :AAAA, :PTR, :SRV, etc.
    class: :IN
  }]
}

# Response
%DNS.Message{
  header: %DNS.Header{
    id: non_neg_integer(),     # Matches query ID
    qr: true,                  # Response
    rcode: atom()              # :NOERROR, :NXDOMAIN, :SERVFAIL
  },
  answers: [%DNS.ResourceRecord{...}]
}
```

### DHCPv4 Message

DHCP message structure from ex_dhcp library.

```elixir
%DHCPv4.Message{
  op: :BOOTREQUEST | :BOOTREPLY,
  htype: 1,                    # Ethernet
  hlen: 6,                     # MAC address length
  xid: non_neg_integer(),      # Transaction ID
  flags: non_neg_integer(),    # Broadcast flag
  ciaddr: :inet.ip4_address(), # Client IP
  yiaddr: :inet.ip4_address(), # Your IP (offered)
  siaddr: :inet.ip4_address(), # Server IP
  giaddr: :inet.ip4_address(), # Gateway IP
  chaddr: binary(),            # Client hardware address (MAC)
  options: [{integer(), binary()}]
}
```

**Message Types** (Option 53):
- `1` - DISCOVER
- `2` - OFFER
- `3` - REQUEST
- `5` - ACK
- `6` - NAK

### DHCPv6 Message

```elixir
%DHCPv6.Message{
  msg_type: atom(),            # :SOLICIT, :ADVERTISE, :REQUEST, :REPLY
  transaction_id: binary(),    # 3-byte transaction ID
  options: [DHCPv6.Option.t()]
}
```

**Message Types**:
- `:SOLICIT` (1) - Client seeking servers
- `:ADVERTISE` (2) - Server response to SOLICIT
- `:REQUEST` (3) - Client requesting address
- `:REPLY` (7) - Server response to REQUEST

### Test Configuration

Test helper configuration (not persisted).

```elixir
# DNS test config
%{
  zone_data: String.t(),       # Zone file content for test zone
  test_domain: String.t(),     # e.g., "e2e-test.local"
  expected_ip: :inet.ip4_address()
}

# DHCPv4 test config
%{
  pool_start: :inet.ip4_address(),
  pool_end: :inet.ip4_address(),
  lease_time: pos_integer(),
  test_mac: binary()
}

# DHCPv6 test config
%{
  pool_prefix: binary(),       # IPv6 prefix
  test_duid: binary()          # DHCP Unique Identifier
}

# mDNS test config
%{
  service_name: String.t(),    # e.g., "Test HTTP Server"
  service_type: String.t(),    # e.g., "_http._tcp"
  service_port: pos_integer()
}
```

## Relationships

```
E2ETest.ServiceContext
    │
    ├── DNS Server ──→ DNS.Message (query/response)
    │
    ├── mDNS Server ──→ DNS.Message (PTR/SRV/TXT queries)
    │
    ├── DHCPv4 Server ──→ DHCPv4.Message (DISCOVER/OFFER/REQUEST/ACK)
    │
    └── DHCPv6 Server ──→ DHCPv6.Message (SOLICIT/ADVERTISE/REQUEST/REPLY)
```

## State Transitions

### DNS E2E Test Flow
```
[Start] → Server Started → Query Sent → Response Received → Verified → [End]
```

### DHCP E2E Test Flow
```
[Start] → Server Started → DISCOVER → OFFER → REQUEST → ACK → Lease Verified → [End]
```

### mDNS E2E Test Flow
```
[Start] → Server Started → Service Registered → PTR Query → Service Discovered → [End]
```

## Validation Rules

1. **Port Assignment**: Port must be > 0 after auto-selection
2. **DNS Response**: Response ID must match query ID
3. **DHCP XID**: Transaction ID must match across DISCOVER/OFFER/REQUEST/ACK
4. **mDNS Service**: Registered service must appear in PTR response
5. **Cleanup**: Server PID must be dead after on_exit callback
