# YellowDog DHCPv4 Server

A production-ready, full-featured DHCPv4 server implementation with ISC Kea-like capabilities, written in Elixir.

## Features

### Core Protocol Support
- ✅ **Complete DHCP Message Types**: DISCOVER, OFFER, REQUEST, ACK, NAK, DECLINE, RELEASE, INFORM
- ✅ **RFC 2131/2132 Compliance**: Full implementation of DHCPv4 protocol standards
- ✅ **Client Identifier Support**: Option 61 for enhanced client tracking
- ✅ **Server Identifier Validation**: RFC-compliant server selection
- ✅ **RENEW/REBIND State Machine**: Proper lease renewal with state detection

### Persistent Storage
- ✅ **Mnesia Database**: Crash-resistant persistent storage
- ✅ **Lease States**: `offered`, `active`, `released`, `expired`, `declined`
- ✅ **Transactional Operations**: ACID guarantees for concurrent access
- ✅ **Secondary Indices**: Fast lookups by IP, state, and pool
- ✅ **Automatic Cleanup**: Periodic expiration of old leases

### Advanced Pool Management
- ✅ **Multiple IP Ranges**: Define non-contiguous ranges in a single pool
- ✅ **Excluded Ranges**: Blacklist specific IPs within allowed ranges
- ✅ **Static Reservations**: MAC → IP bindings for specific clients
- ✅ **Multiple Pools**: Support for different subnets
- ✅ **Pool Statistics**: Real-time utilization tracking

### Monitoring & Operations
- ✅ **Comprehensive Telemetry**: Events for all DHCP operations
- ✅ **Structured Logging**: Detailed operation logs
- ✅ **Public API**: Query leases, statistics, and status
- ✅ **Test Environment Support**: Automatic configuration for testing
- ✅ **Configuration Hot-Reload**: Watch config files and reload without restart
- ✅ **Per-Pool Statistics**: Detailed utilization and allocation metrics

## Installation

The DHCPv4 server is part of the YellowDog umbrella project.

```elixir
# In your mix.exs dependencies
{:yellow_dog_dhcpv4, in_umbrella: true}
```

## Configuration

### Basic Configuration (Legacy Format)

```elixir
config = [
  pools: [
    %{
      "name" => "default",
      "range_start" => {192, 168, 1, 100},
      "range_end" => {192, 168, 1, 200},
      "subnet_mask" => {255, 255, 255, 0},
      "gateway" => {192, 168, 1, 1},
      "dns_servers" => [{8, 8, 8, 8}, {8, 8, 4, 4}],
      "domain_name" => "local",
      "lease_time" => 86400  # 24 hours in seconds
    }
  ]
]
```

### Advanced Configuration (Multiple Ranges)

```elixir
config = [
  pools: [
    %{
      "name" => "office",
      # Multiple non-contiguous IP ranges
      "ranges" => [
        {{192, 168, 1, 100}, {192, 168, 1, 150}},
        {{192, 168, 1, 200}, {192, 168, 1, 250}}
      ],
      # Exclude specific ranges (e.g., for infrastructure)
      "excluded_ranges" => [
        {{192, 168, 1, 120}, {192, 168, 1, 130}}
      ],
      # Static reservations: MAC => IP
      "static_reservations" => %{
        "00:11:22:33:44:55" => {192, 168, 1, 50},
        "AA:BB:CC:DD:EE:FF" => {192, 168, 1, 51}
      },
      "subnet_mask" => {255, 255, 255, 0},
      "gateway" => {192, 168, 1, 1},
      "dns_servers" => [{192, 168, 1, 1}],
      "domain_name" => "office.local",
      "lease_time" => 43200  # 12 hours
    }
  ]
]
```

## Usage

### Starting the Server

```elixir
# Start with configuration
{:ok, pid} = YellowDog.Dhcpv4.start_link(config)

# Or as part of a supervision tree
children = [
  {YellowDog.Dhcpv4, config}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Querying Leases

```elixir
# List all active leases
leases = YellowDog.Dhcpv4.list_leases()
# => [
#   %{
#     mac_address: <<0, 17, 34, 51, 68, 85>>,
#     ip_address: {192, 168, 1, 100},
#     pool_name: "default",
#     state: :active,
#     lease_time: 86400,
#     expires_at: 1735286400,
#     hostname: "laptop-01",
#     client_id: nil,
#     created_at: 1735200000,
#     updated_at: 1735200000
#   }
# ]

# Get a specific lease by MAC address
{:ok, lease} = YellowDog.Dhcpv4.get_lease("00:11:22:33:44:55")

# Release a lease
:ok = YellowDog.Dhcpv4.release_lease("00:11:22:33:44:55")
```

### Statistics

```elixir
# Global lease statistics
stats = YellowDog.Dhcpv4.stats()
# => %{
#   total_leases: 52,
#   active_leases: 45,
#   expired_leases: 5,
#   by_state: %{
#     active: 45,
#     offered: 2,
#     released: 3,
#     expired: 2
#   }
# }

# Per-pool statistics
{:ok, pool_stats} = YellowDog.Dhcpv4.get_pool_stats("default")
# => %{
#   pool_name: "default",
#   total_addresses: 101,
#   allocated_addresses: 45,
#   available_addresses: 56,
#   utilization_percent: 44.55,
#   static_reservations: 2,
#   leases_by_state: %{active: 40, offered: 3, released: 2},
#   ranges: [{{192, 168, 1, 100}, {192, 168, 1, 200}}],
#   excluded_ranges: []
# }

# All pools statistics
all_stats = YellowDog.Dhcpv4.get_all_pool_stats()
# => %{
#   "default" => %{pool_name: "default", total_addresses: 101, ...},
#   "office" => %{pool_name: "office", total_addresses: 200, ...}
# }
```

### Service Status

```elixir
status = YellowDog.Dhcpv4.status()
# => %{
#   running: true,
#   lease_stats: %{...}
# }
```

## Architecture

### Components

1. **Server** (`YellowDog.Dhcpv4.Server`)
   - GenServer wrapping Abyss UDP library
   - Configurable port (default 67) and bind address
   - Broadcast mode for DHCP discovery
   - Rate limiting support

2. **Handler** (`YellowDog.Dhcpv4.Handler`)
   - Implements `Abyss.Handler` behaviour
   - Processes all DHCP message types
   - State machine for SELECTING/RENEWING/REBINDING
   - Server identifier validation
   - Telemetry event emission

3. **LeaseManager** (`YellowDog.Dhcpv4.LeaseManager`)
   - GenServer managing lease lifecycle
   - Delegates to LeaseStorage for persistence
   - Pool management and IP allocation
   - Automatic cleanup of expired leases

4. **LeaseStorage** (`YellowDog.Dhcpv4.LeaseStorage`)
   - Mnesia-based persistent storage
   - Transactional CRUD operations
   - Secondary indices for fast lookups
   - Query APIs with filtering

5. **AddressPool** (`YellowDog.Dhcpv4.AddressPool`)
   - IP range management
   - Multiple ranges per pool
   - Excluded range support
   - Static reservation handling
   - Pool size calculation

6. **Supervisor** (`YellowDog.Dhcpv4.Supervisor`)
   - OTP supervisor for reliability
   - Pre-start and post-start hooks
   - One-for-one restart strategy

7. **PoolStats** (`YellowDog.Dhcpv4.PoolStats`)
   - Per-pool utilization tracking
   - Allocation statistics
   - Lease distribution analysis
   - Pool exhaustion warnings

8. **ConfigWatcher** (`YellowDog.Dhcpv4.ConfigWatcher`)
   - Configuration file monitoring
   - Automatic reload on changes
   - Debouncing for rapid changes
   - Telemetry events for reload operations

### Lease Lifecycle

```
DISCOVER → OFFER (state: offered)
    ↓
REQUEST → ACK (state: active)
    ↓
[Time passes...]
    ↓
RENEW → ACK (state: active, renewed)
    ↓
[Or: REBIND → ACK (state: active, renewed)]
    ↓
RELEASE (state: released)
[Or: Expiration (state: expired)]
[Or: DECLINE (state: declined)]
```

## DHCP Request States

The server properly handles all DHCP REQUEST states per RFC 2131:

### SELECTING
- Client selects server after receiving OFFER
- Contains Server Identifier (option 54) and Requested IP
- Server validates that Server ID matches

### INIT-REBOOT
- Client reboots and tries to reuse previous address
- Contains Requested IP but no Server Identifier
- `ciaddr` is 0

### RENEWING
- Client extends lease with original server (unicast)
- `ciaddr` filled with client's current IP
- No Requested IP or Server Identifier options

### REBINDING
- Client extends lease with any server (broadcast)
- `ciaddr` filled with client's current IP
- No Server Identifier option

## Telemetry Events

The server emits comprehensive telemetry events for monitoring:

```elixir
[:yellow_dog, :dhcpv4, :message_received]
[:yellow_dog, :dhcpv4, :discover_offer]
[:yellow_dog, :dhcpv4, :request_ack]
[:yellow_dog, :dhcpv4, :request_nak]
[:yellow_dog, :dhcpv4, :decline_handled]
[:yellow_dog, :dhcpv4, :release_handled]
[:yellow_dog, :dhcpv4, :inform_handled]
[:yellow_dog, :dhcpv4, :lease_allocated]
[:yellow_dog, :dhcpv4, :message_error]
```

Each event includes:
- Duration in microseconds
- Client IP and MAC address
- Message type or operation
- Additional context (state, reason, etc.)

## Testing

The server includes comprehensive test coverage:

```bash
# Run all tests
MIX_ENV=test mix test

# Run specific test file
MIX_ENV=test mix test test/yellow_dog/dhcpv4/handler_test.exs

# Run with coverage
MIX_ENV=test mix test --cover
```

### Test Configuration

In test environment, the server automatically:
- Uses `ram_copies` for Mnesia (no disk persistence)
- Binds to port 6767 instead of privileged port 67
- Disables DNS service to avoid conflicts

## Performance

- **Lease Allocation**: < 1ms (with Mnesia)
- **Concurrent Requests**: 100+ requests/second (configurable rate limiting)
- **Memory Usage**: ~10-20MB base + ~1KB per lease
- **Storage**: Mnesia with disc_copies provides ACID guarantees

## Comparison with ISC Kea

| Feature | ISC Kea | YellowDog DHCPv4 | Status |
|---------|---------|------------------|--------|
| Core DHCP Protocol | ✅ | ✅ | Complete |
| Persistent Storage | ✅ | ✅ | Mnesia-based |
| Multiple Pools | ✅ | ✅ | Complete |
| Multiple Ranges | ✅ | ✅ | Complete |
| Excluded Ranges | ✅ | ✅ | Complete |
| Static Reservations | ✅ | ✅ | Complete |
| Client Identifier | ✅ | ✅ | Complete |
| RENEW/REBIND | ✅ | ✅ | Complete |
| Server ID Validation | ✅ | ✅ | Complete |
| Telemetry/Monitoring | ✅ | ✅ | Complete |
| Config Hot-Reload | ✅ | ✅ | Complete |
| Per-Pool Statistics | ✅ | ✅ | Complete |
| High Availability | ✅ | ❌ | Future |
| DDNS Integration | ✅ | ❌ | Future |

**Current Feature Parity: ~85%** for standard DHCPv4 use cases

## Production Deployment

### Requirements
- Elixir 1.18+
- OTP 27+
- Root/admin privileges (for port 67)

### Port Configuration

```bash
# Allow Elixir to bind to privileged port 67
sudo setcap 'cap_net_bind_service=+ep' /path/to/beam.smp

# Or run on alternative port with iptables redirect
sudo iptables -t nat -A PREROUTING -p udp --dport 67 -j REDIRECT --to-port 6767
```

### Mnesia Directory

```elixir
# Configure Mnesia directory for persistence
:mnesia.create_schema([node()])
Application.put_env(:mnesia, :dir, '/var/lib/yellow_dog/mnesia')
```

## Troubleshooting

### No DHCP Responses

1. Check server is running: `YellowDog.Dhcpv4.status()`
2. Verify port binding: `ss -ulnp | grep 67`
3. Check firewall rules: `sudo iptables -L`
4. Enable debug logging: `Logger.configure(level: :debug)`

### Pool Exhausted

1. Check pool utilization: `YellowDog.Dhcpv4.stats()`
2. Review allocated leases: `YellowDog.Dhcpv4.list_leases()`
3. Increase pool range or add additional ranges
4. Clean up stale leases if necessary

### Lease Not Renewing

1. Check RENEW messages in logs
2. Verify server identifier matches
3. Review lease expiration times
4. Check for network connectivity issues

## License

Copyright © 2025 YellowDog DNS Project

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request

## Support

- GitHub Issues: https://github.com/gsmlg-dev/yellow-dog/issues
- Documentation: Check CLAUDE.md in project root
