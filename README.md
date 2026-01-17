# Yellow Dog DNS

![Yellow Dog DNS](./priv/yellow_dog.png)

Yellow Dog DNS is a distributed DNS and DHCP server written in Elixir/Erlang. It provides a complete network services suite including DNS, mDNS, DHCPv4, and DHCPv6 with a modern web console for management.

## Features

- **DNS Server** - Authoritative and forwarding DNS with zone management
- **mDNS Responder** - Multicast DNS with service discovery and registration
- **DHCPv4 Server** - Full DHCPv4 implementation with lease management
- **DHCPv6 Server** - Full DHCPv6 implementation with DUID-based identification
- **Web Console** - Phoenix LiveView dashboard with real-time monitoring
- **Service Diagnostics** - Built-in diagnostic tools for DNS/mDNS/DHCP queries

## Quick Start

### Running the Server

```shell
# Start all applications
mix run --no-halt

# Start with interactive shell
iex -S mix

# Start the web console (development)
cd apps/yellow_dog_console
mix phx.server
# Visit http://localhost:4000
```

### Default Ports

| Service | Port | Protocol |
|---------|------|----------|
| DNS     | 53   | UDP      |
| mDNS    | 5353 | UDP (multicast) |
| DHCPv4  | 67   | UDP      |
| DHCPv6  | 547  | UDP      |
| Web Console | 4000 | HTTP |

## Architecture

Yellow Dog DNS is organized as an Elixir umbrella project with 10 applications:

### Core Applications

- **YellowDog** - Core application with configuration management and orchestration
- **YellowDog.Telemetry** - Centralized telemetry and metrics functionality
- **YellowDog.Dns** - DNS functionality including name resolution, zones, and views
- **YellowDog.Dhcpv4** - DHCPv4 protocol implementation with full lease management
- **YellowDog.Dhcpv6** - DHCPv6 protocol implementation with full lease management
- **YellowDog.Mdns** - mDNS responder with service discovery and registration
- **YellowDogConsole** - Phoenix LiveView web console with DaisyUI

### Infrastructure Libraries

- **abyss** - High-performance pure Elixir UDP server library
- **ex_dns** - Pure Elixir DNS protocol library (resource records, zone management)
- **ex_dhcp** - Pure Elixir DHCP protocol library (DHCPv4/v6 message handling)

## Configuration

Configuration is managed through TOML files. Default configuration:

```toml
[core]
dns = true
mdns = true
dhcpv4 = true
dhcpv6 = true

[dns]
listen = "0.0.0.0"
port = 53
mode = "forward"
upstream_servers = ["8.8.8.8", "1.1.1.1"]

[mdns]
listen = "0.0.0.0"
port = 5353

[dhcpv4]
listen = "0.0.0.0"
port = 67

[dhcpv6]
listen = "::"
port = 547
```

### Programmatic Configuration

```elixir
# Get configuration
YellowDog.get_config(:key)
YellowDog.get_all_config()

# Check service status
YellowDog.get_all_status()
YellowDog.get_service_status(:dns)

# Service management
YellowDog.list_services()
# => [:dns, :mdns, :dhcpv4, :dhcpv6]
```

## Data and Storage

Yellow Dog DNS stores runtime data and configuration in the following locations:

### Data Directory Structure

```
data/                           # Runtime data (not version controlled)
├── dns/
│   ├── views.toml              # DNS views configuration
│   ├── zones.toml              # DNS zones configuration
│   └── zones/                  # Zone file storage (BIND format)
│       └── example.com.zone
└── mdns_services.toml          # mDNS service registrations
```

### Configuration Files

| File | Description |
|------|-------------|
| `data/dns/views.toml` | DNS view definitions with ACL rules |
| `data/dns/zones.toml` | Zone metadata (type, name, upstreams) |
| `data/dns/zones/*.zone` | Zone data files in BIND format |
| `data/mdns_services.toml` | Registered mDNS services |
| `config/config.exs` | Application configuration |
| `config/runtime.exs` | Runtime configuration |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `YELLOW_DOG_DATA_DIR` | Base directory for runtime data | `./data` |
| `YELLOW_DOG_CONFIG_FILE` | Path to main config file | `./config.toml` |

### Persistence

- **DNS Zones**: Zone records are persisted to BIND-format zone files in `data/dns/zones/`
- **Views & Zones Config**: View and zone metadata is saved to TOML files automatically
- **Backup Files**: `.backup` files are created before each save operation

## Development

### Project Structure

```
yellow_dog/                     # Umbrella project root
├── apps/                       # Application directory
│   ├── yellow_dog/             # Core application
│   ├── yellow_dog_telemetry/   # Telemetry package
│   ├── yellow_dog_dns/         # DNS functionality
│   ├── yellow_dog_dhcpv4/      # DHCPv4 protocol
│   ├── yellow_dog_dhcpv6/      # DHCPv6 protocol
│   ├── yellow_dog_mdns/        # mDNS functionality
│   ├── yellow_dog_console/     # Phoenix web console
│   ├── abyss/                  # UDP server library
│   ├── ex_dns/                 # DNS protocol library
│   └── ex_dhcp/                # DHCP protocol library
├── e2e_test/                   # End-to-end tests
├── config/                     # Configuration files
├── priv/                       # Static assets
└── mix.exs                     # Umbrella mix file
```

### Development Environment

This project uses [devenv](https://devenv.sh) for development environment management:

```bash
# Activate the development environment
direnv allow  # or use devenv shell

# The environment includes:
# - Elixir 1.18 with OTP 27
# - Git, figlet, lolcat, watchman, inotify-tools
# - JavaScript support with pnpm and bun
# - Tailwind CSS 4
```

### Running Tests

```shell
# Run all tests
mix test

# Run tests for specific app
mix test apps/yellow_dog_dns

# Run E2E tests
mix test.e2e

# Run E2E tests for specific service
mix test.e2e.dns
mix test.e2e.mdns
mix test.e2e.dhcpv4
mix test.e2e.dhcpv6
```

### Building

```shell
# Compile all applications
mix compile

# Format code
mix format

# Run linting
mix lint

# Run Dialyzer
mix dialyzer

# Build release
mix release

# Build Docker image
nix build .#docker
```

## DNS Benchmarking

```shell
# Create test queries
echo "www.example.com A" > t.txt
echo "www.google.com A" >> t.txt

# Run DNS performance test
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 53
```

## Web Console

The web console provides a modern interface for managing Yellow Dog DNS:

- **Dashboard** - Real-time service status and statistics
- **DNS Management** - Zone configuration and query logs
- **mDNS Services** - Service registration and discovery
- **DHCP Leases** - Lease management for DHCPv4/v6
- **Diagnostics** - Interactive query tools for DNS, mDNS, DHCP
- **Settings** - Service configuration management

### Starting the Console

```shell
cd apps/yellow_dog_console
mix setup              # Install dependencies
mix phx.server         # Start server at http://localhost:4000
```

## Docker

```shell
# Build Docker image
docker build -t yellowdogdns .

# Or use Nix
nix build .#docker

# Run container
docker run -p 53:53/udp -p 67:67/udp -p 4000:4000 yellowdogdns
```

## License

Yellow Dog DNS is open source software.
