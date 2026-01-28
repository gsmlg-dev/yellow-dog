# YellowDog.Mdns

**Multicast DNS (mDNS) service discovery and responder for YellowDog.**

## Features

- 🎯 **Full RFC 6762 mDNS implementation** (in progress)
- 📝 **Service registration** via file or API
- 🔄 **Hot-reload** configuration changes
- 🔍 **Network discovery** - discover services on local network
- 📡 **Active responder** - advertise local services
- 🎚️ **Configurable modes**: listener-only, responder-only, or hybrid
- 💾 **Persistent storage** in TOML or JSON format
- 🌐 **Web UI integration** via Phoenix LiveView (planned)

## Quick Start

### Register Services via File

Create `data/mdns/services.toml`:

```toml
[[service]]
name = "My Web Server"
type = "_http._tcp"
port = 8080
enabled = true

  [service.txt]
  path = "/api"
  version = "1.0"

  [service.addresses]
  ipv4 = ["192.168.1.100"]
```

### Register Services via API

```elixir
YellowDog.Mdns.ServiceRegistry.register_service(%{
  name: "API Server",
  type: "_http._tcp",
  port: 8080,
  txt: %{"version" => "1.0"},
  addresses: ["192.168.1.100"]
}, persist: true)
```

### Discover Network Services

```elixir
# List all discovered services
YellowDog.Mdns.list_discovered_services()

# Search for specific service types
YellowDog.Mdns.discover_services(type: "_http._tcp")

# Get network statistics
YellowDog.Mdns.network_stats()
```

## Configuration

Add to your `config.toml`:

```toml
[mdns]
listen = "0.0.0.0"
port = 5353
mode = "hybrid"  # listener | responder | hybrid

[mdns.services]
file = "data/mdns/services.toml"
format = "toml"
auto_save = true
watch_file = true
load_on_start = true

[mdns.responder]
enabled = true
service_ttl = 4500
host_ttl = 120
enable_probing = true
enable_announcements = true

[mdns.monitor]
enabled = true
cache_responses = true
log_queries = true
```

## Architecture

```
YellowDog.Mdns
├── Server (Abyss UDP multicast)
├── ServiceRegistry (ETS service storage)
├── ServiceStore (file persistence)
├── FileWatcher (hot-reload)
├── RecordBuilder (DNS records)
├── MessageCache (network monitoring)
├── Handler (dual-mode routing)
└── Public API
```

## Implementation Status

✅ **Phase 1 Complete**: Foundation + Persistence
- Service registration and management
- File persistence (TOML/JSON)
- Hot-reload via file watching
- DNS record builders
- Comprehensive test coverage

See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for detailed progress.

## Testing

```bash
# Run all tests
mix test apps/yellow_dog_mdns

# Run specific test
mix test apps/yellow_dog_mdns/test/yellow_dog/mdns/service_store_test.exs

# With coverage
mix test --cover apps/yellow_dog_mdns
```

## API Reference

### Service Management

```elixir
# Register service
{:ok, service_id} = YellowDog.Mdns.ServiceRegistry.register_service(service_def, opts)

# List services
services = YellowDog.Mdns.ServiceRegistry.list_services(filter: :enabled)

# Get service
service = YellowDog.Mdns.ServiceRegistry.get_service(service_id)

# Update service
:ok = YellowDog.Mdns.ServiceRegistry.update_service(service_id, updates, persist: true)

# Toggle service
:ok = YellowDog.Mdns.ServiceRegistry.toggle_service(service_id)

# Statistics
stats = YellowDog.Mdns.ServiceRegistry.stats()
```

### File Operations

```elixir
# Load services
{:ok, services} = YellowDog.Mdns.ServiceStore.load_services(file_path)

# Save services
:ok = YellowDog.Mdns.ServiceStore.save_services(file_path, services)

# Validate
:ok = YellowDog.Mdns.ServiceStore.validate_service(service_def)
```

### Network Discovery

```elixir
# Query cache
entries = YellowDog.Mdns.query("printer.local")
entries = YellowDog.Mdns.query("_http._tcp.local", :PTR)

# List all
all = YellowDog.Mdns.list_all()

# Statistics
stats = YellowDog.Mdns.stats()
```

## Service Definition Format

```elixir
%{
  name: "Service Name",        # Required: human-readable name
  type: "_http._tcp",           # Required: service type (with protocol)
  port: 8080,                   # Required: port number (1-65535)
  host: "myhost",               # Optional: hostname (defaults to system hostname)
  txt: %{                       # Optional: TXT record key-value pairs
    "key" => "value",
    "version" => "1.0"
  },
  addresses: [                  # Optional: IP addresses
    "192.168.1.100",            # IPv4
    "fe80::1"                   # IPv6
  ],
  enabled: true                 # Optional: enable/disable (default: true)
}
```

## Service Types

Common mDNS service types:
- `_http._tcp` - Web servers
- `_https._tcp` - Secure web servers
- `_ssh._tcp` - SSH servers
- `_ftp._tcp` - FTP servers
- `_printer._tcp` - Printers
- `_airplay._tcp` - AirPlay
- `_googlecast._tcp` - Chromecast
- `_workstation._tcp` - Workstations

## Links

- [RFC 6762: Multicast DNS](https://www.rfc-editor.org/rfc/rfc6762.html)
- [RFC 6763: DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html)
- [Implementation Status](IMPLEMENTATION_STATUS.md)
- [Yellow Dog Documentation](../../CLAUDE.md)

## License

Part of the YellowDog DNS project.
