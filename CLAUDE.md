# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yellow Dog DNS is a distributed DNS and DHCP server written in Erlang/Elixir using an umbrella project structure. The project has been completely refactored to use dot-notation module naming across all applications and now includes 10 applications total - 7 core YellowDog applications and 3 infrastructure libraries.

### Applications (10 total)

**Core YellowDog Applications:**
- **YellowDog** - Core application with configuration management and orchestration
- **YellowDog.Telemetry** - Centralized telemetry and metrics functionality
- **YellowDog.Dns** - DNS functionality including name resolution, zones, and views
- **YellowDog.Dhcpv4** - DHCPv4 protocol implementation (complete with server and handler)
- **YellowDog.Dhcpv6** - DHCPv6 protocol implementation (complete with server and handler)
- **YellowDog.Mdns** - mDNS (multicast DNS) functionality (basic structure)
- **YellowDogConsole** - Phoenix-based web console for management and monitoring

**Infrastructure Libraries (now in apps/ directory):**
- **abyss** - High-performance pure Elixir UDP server library
- **ex_dns** - Pure Elixir DNS protocol library (resource records, zone management)
- **ex_dhcp** - Pure Elixir DHCP protocol library (DHCPv4/v6 message handling)

All modules follow the `YellowDog.<AppName>.ModuleName` pattern, and directory structures reflect the module hierarchy (e.g., `apps/yellow_dog_dns/lib/yellow_dog/dns/`).

### Recent Architecture Migration
The project has recently completed a major migration:
- Infrastructure libraries (abyss, ex_dns, ex_dhcp) were moved from external dependencies to umbrella applications
- All protocol applications now use `in_umbrella: true` dependencies instead of external Hex packages
- Dependency names updated: `dhcp_ex` → `ex_dhcp` throughout the codebase
- Shared build paths configured for infrastructure apps: `build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`
- This provides better integration, unified builds, and easier development workflows

## Development Environment Setup

This project uses [devenv](https://devenv.sh) for development environment management:

```bash
# Activate the development environment
direnv allow  # or use devenv shell

# Alternative: Use Nix directly
nix develop  # Traditional Nix shell development
nix shell    # Interactive development shell

# The environment includes:
# - Elixir 1.18 with OTP 27 (beam27Packages)
# - Git, figlet, lolcat, watchman, inotify-tools
# - JavaScript support with pnpm and bun
# - Tailwind CSS 4
# - Custom hello script that displays "YellowDog"
```

## Common Commands

### Running the Application
```bash
# Start all applications
mix run --no-halt

# Start in interactive Elixir shell (IEx)
iex -S mix

# Start specific applications
mix app.start yellow_dog
mix app.start yellow_dog_dns

# Start the Phoenix web console (development mode)
cd apps/yellow_dog_console
mix phx.server
# Then visit http://localhost:4000

# Start Phoenix console with IEx
cd apps/yellow_dog_console
iex -S mix phx.server
```

### Testing
```bash
# Run all tests (umbrella-level alias)
mix test

# Run tests for specific app
mix test apps/yellow_dog_dns

# Run tests for specific path
mix test path/to/test_file.exs

# Run tests for specific app only
MIX_ENV=test mix test apps/yellow_dog_dhcpv4

# Run single test file
mix test apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/handler_test.exs

# Special test commands for abyss library
cd apps/abyss
mix test                    # Run tests with coverage
mix test.all                # Run all tests including integration and slow tests
mix test.unit               # Run only unit tests (exclude integration/slow)
mix test.integration        # Run integration tests only
```

### Code Formatting and Linting
```bash
# Format all code according to .formatter.exs configuration
mix format

# Check code formatting without modifying files
mix format --check-formatted

# Run linting (umbrella-level alias runs across all apps)
mix lint

# Run Credo linting with strict mode
mix credo

# Run Dialyzer static type analysis
mix dialyzer

# The formatter covers mix.exs, config/*.exs, and all apps/* subdirectories
# Each app also has its own 'lint' alias that runs 'credo --strict' and 'dialyzer'
```

### Dependencies
```bash
# Get dependencies
mix deps.get

# Update dependencies
mix deps.update

# Compile dependencies
mix deps.compile
```

### Building and Publishing
```bash
# Compile with warnings as errors (as done in CI)
mix compile --warnings-as-errors

# Check code formatting
mix format --check-formatted

# Publish to Hex (includes formatting)
mix publish

# Nix builds
nix build              # Build Elixir release
nix build .#docker     # Build Docker image

# Build web console assets
cd apps/yellow_dog_console
mix setup              # Install dependencies and setup assets
mix assets.build       # Build assets (tailwind + esbuild)
mix assets.deploy      # Build minified assets for production
```

### Clean Build
```bash
# Clean all compiled artifacts
mix clean

# Clean and rebuild everything
mix clean && mix compile
```

## Architecture

This is an Elixir umbrella project with 10 applications. The infrastructure libraries (abyss, ex_dns, ex_dhcp) are now integrated as umbrella applications, and a Phoenix-based web console provides management and monitoring capabilities.

### YellowDog (Core Application)
- **Location**: `apps/yellow_dog/`
- **Purpose**: Configuration management, orchestration, and public API
- **Application Module**: `YellowDog.Application`
- **Key Modules**:
  - `YellowDog.Config` - Configuration management with TOML support and Agent-based storage
  - `YellowDog.ServerConfig` - Server configuration
  - `YellowDog.Server` - Main server orchestration
  - `YellowDog` - Public API (exposed through `apps/yellow_dog/lib/yellow_dog.ex`)

### YellowDog.Telemetry (Telemetry Package)
- **Location**: `apps/yellow_dog_telemetry/`
- **Purpose**: Centralized telemetry and metrics functionality
- **Application Module**: Standalone package
- **Dependencies**: `telemetry`
- **Key Modules**:
  - `YellowDog.Telemetry` - Core telemetry functionality and span management

### Infrastructure Libraries

**abyss (UDP Server Library)**
- **Location**: `apps/abyss/`
- **Purpose**: High-performance pure Elixir UDP server
- **Key Modules**: `Abyss.Server`, `Abyss.ServerConfig`, `Abyss.Transport.UDP`, `Abyss.RateLimiter`
- **Features**: Connection pooling, rate limiting, telemetry events, broadcast mode support

**ex_dns (DNS Protocol Library)**
- **Location**: `apps/ex_dns/`
- **Purpose**: DNS protocol handling, resource records, and zone management
- **Key Modules**: `DNS.Message`, `DNS.Zone`, `DNS.ResourceRecordType`, `DNS.Parameter` protocol
- **Features**: Complete DNS message parsing, zone management, 20+ record types, DNSSEC support

**ex_dhcp (DHCP Protocol Library)**
- **Location**: `apps/ex_dhcp/`
- **Purpose**: DHCP protocol implementation for both DHCPv4 and DHCPv6
- **Key Modules**: `DHCPv4.Message`, `DHCPv6.Message`, `DHCP.Parameter` protocol
- **Features**: RFC-compliant DHCPv4/v6 message handling, binary serialization, secure random generation

### Protocol Applications (YellowDog.*)

**YellowDog.Dns (DNS Application)**
- **Location**: `apps/yellow_dog_dns/`
- **Purpose**: DNS protocol handling and name resolution
- **Dependencies**: `ex_dns`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_dns/lib/yellow_dog/dns/`
- **Key Modules**:
  - `YellowDog.Dns.NameResolver` - DNS name resolution
  - `YellowDog.Dns.ViewManager` - DNS view management
  - `YellowDog.Dns.View` - DNS views and zones
  - `YellowDog.Dns.Handler.UDP` - UDP DNS packet handling
  - **View Submodules**: `YellowDog.Dns.View.ACL`, `YellowDog.Dns.View.Cache`, `YellowDog.Dns.View.Resolver`, `YellowDog.Dns.View.ZoneManager`, etc.
- **Status**: Basic structure with ViewManager, NameResolver, placeholder supervisor

**YellowDog.Dhcpv4 (DHCPv4 Application)**
- **Location**: `apps/yellow_dog_dhcpv4/`
- **Purpose**: DHCPv4 protocol implementation with full server functionality
- **Dependencies**: `ex_dhcp`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/`
- **Key Modules**:
  - `YellowDog.Dhcpv4.Server` - DHCPv4 server using Abyss UDP library
  - `YellowDog.Dhcpv4.Handler` - DHCPv4 message handler implementing Abyss.Handler behaviour
  - `YellowDog.Dhcpv4.Supervisor` - DHCPv4 supervisor with pre/post-start tasks
  - `YellowDog.Dhcpv4.LeaseManager` - GenServer for lease allocation and tracking with ETS storage
  - `YellowDog.Dhcpv4.AddressPool` - IP address pool management and allocation logic
- **Features**:
  - Complete DHCPv4 protocol support (DISCOVER, OFFER, REQUEST, ACK, DECLINE, RELEASE, INFORM)
  - IPv4 broadcast handling for client discovery
  - Configurable address pools with range management
  - Lease tracking and expiration with ETS-based persistence
  - Static IP reservations (MAC → IP binding)
  - Automatic lease renewal and cleanup
  - Comprehensive telemetry events for monitoring
  - TOML-based configuration with multiple pool support
- **Configuration**: Pools, lease times, DNS servers, gateway, and domain name configured via TOML
- **Status**: Production-ready with full lease management

**YellowDog.Dhcpv6 (DHCPv6 Application)**
- **Location**: `apps/yellow_dog_dhcpv6/`
- **Purpose**: DHCPv6 protocol implementation with full server functionality
- **Dependencies**: `ex_dhcp`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/`
- **Key Modules**:
  - `YellowDog.Dhcpv6.Server` - DHCPv6 server using Abyss UDP library
  - `YellowDog.Dhcpv6.Handler` - DHCPv6 message handler implementing Abyss.Handler behaviour
  - `YellowDog.Dhcpv6.Supervisor` - DHCPv6 supervisor with pre/post-start tasks
  - `YellowDog.Dhcpv6.LeaseManager` - GenServer for lease allocation and tracking with ETS storage
  - `YellowDog.Dhcpv6.AddressPool` - IPv6 address pool management and allocation logic
- **Features**:
  - Complete DHCPv6 protocol support (SOLICIT, ADVERTISE, REQUEST, REPLY, RENEW, REBIND, RELEASE, DECLINE, INFORMATION-REQUEST)
  - IPv6 multicast support for client discovery
  - DUID-based client identification (DHCP Unique Identifier)
  - IA_NA (Identity Association for Non-temporary Addresses) support
  - Configurable IPv6 address pools with range management
  - Lease tracking with preferred and valid lifetimes
  - Static IPv6 reservations (DUID → IPv6 binding)
  - Automatic lease renewal and cleanup
  - Comprehensive telemetry events for monitoring
  - TOML-based configuration with multiple pool support
  - DNS server and domain name configuration
- **Configuration**: IPv6 pools, preferred/valid lifetimes, DNS servers, and domain name configured via TOML
- **Status**: Production-ready with full lease management

**YellowDog.Mdns (mDNS Application)**
- **Location**: `apps/yellow_dog_mdns/`
- **Purpose**: Multicast DNS passive listener for service discovery
- **Dependencies**: `ex_dns`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/`
- **Key Modules**:
  - `YellowDog.Mdns.Server` - mDNS server using Abyss UDP library
  - `YellowDog.Mdns.Handler` - Passive mDNS message handler implementing Abyss.Handler behaviour
  - `YellowDog.Mdns.Supervisor` - mDNS supervisor with pre/post-start tasks
  - `YellowDog.Mdns.MessageCache` - GenServer for message caching with ETS storage
- **Features**:
  - Passive listener implementation (receives broadcasts, does NOT respond)
  - Multicast DNS on 224.0.0.251:5353
  - .local domain filtering
  - ETS-based message cache with TTL support
  - Caches DNS answers, authority records, additional records, and questions
  - Periodic cleanup of expired cache entries (every 5 minutes)
  - Query API for retrieving cached messages by domain and record type
  - Cache statistics and management functions
  - Comprehensive telemetry events for monitoring
  - TOML-based configuration
- **Configuration**: Multicast address and port configured via TOML
- **Status**: Production-ready as passive listener and service discovery cache

**YellowDogConsole (Web Console)**
- **Location**: `apps/yellow_dog_console/`
- **Purpose**: Phoenix LiveView-based web console for management and monitoring
- **Dependencies**: `phoenix`, `phoenix_live_dashboard`, `bandit`, `telemetry_metrics`, `gettext`
- **Directory Structure**: `apps/yellow_dog_console/lib/yellow_dog_console/` and `apps/yellow_dog_console/lib/yellow_dog_console_web/`
- **Key Modules**:
  - `YellowDogConsole.Application` - Web application supervisor
  - `YellowDogConsoleWeb.Endpoint` - Phoenix endpoint
  - `YellowDogConsoleWeb.Router` - Web routes
  - `YellowDogConsoleWeb.DashboardLive` - LiveView dashboard
  - `YellowDogConsoleWeb.Telemetry` - Telemetry metrics for web interface
- **Features**: Live dashboard, telemetry visualization, real-time monitoring
- **Status**: Active development

### Inter-Application Dependencies
- All applications depend on `YellowDog` for configuration
- All applications use `YellowDog.Telemetry` for centralized telemetry functionality
- `YellowDog.Dns` and `YellowDog.Mdns` use `ex_dns` for DNS protocol handling
- `YellowDog.Dhcpv4` and `YellowDog.Dhcpv6` use `ex_dhcp` for DHCP protocol handling
- All applications use `abyss` as the UDP server
- `YellowDog.Telemetry` uses `telemetry` as the underlying telemetry library

## Configuration

Configuration is centralized in the core `YellowDog.Config` module with TOML file support:

```elixir
# Get configuration values
YellowDog.get_config(:key)
YellowDog.get_all_config()

# Service-specific configuration
YellowDog.Config.get(:dns, :port)
YellowDog.Config.get_service(:dns)

# Check if service is enabled
YellowDog.Config.service_enabled?(:dns)

# Public API access
YellowDog.start_link()
YellowDog.banner()
```

### Default Configuration Structure
```elixir
%{
  "core" => %{
    "dns" => true, "mdns" => true,
    "dhcpv4" => true, "dhcpv6" => true
  },
  "dns" => %{ "listen" => "0.0.0.0", "port" => 53 },
  "mdns" => %{ "listen" => "0.0.0.0", "port" => 5353 },
  "dhcpv4" => %{ "listen" => "0.0.0.0", "port" => 67 },
  "dhcpv6" => %{ "listen" => "::", "port" => 547 }
}
```

Configuration files are loaded via `YellowDog.Config.load/1` with fallback to defaults.

### Test Environment Configuration
In test environment (`Mix.env() == :test`), the configuration is automatically adjusted:
- DNS service is disabled to avoid privileged port conflicts
- DHCPv4 uses port 6767 instead of privileged port 67
- DHCPv6 uses port 5667 instead of privileged port 547
- IP address strings are automatically converted to tuple format for transport options

## Service Control and Status

The YellowDog system provides comprehensive service control and status monitoring through the `YellowDog.ServiceManager` module and public API functions.

### Service Management API

```elixir
# List all available services
YellowDog.list_services()
# => [:dns, :mdns, :dhcpv4, :dhcpv6]

# Get status of all services
YellowDog.get_all_status()
# => %{
#   dns: %{enabled: true, running: true, uptime: "1h 23m", ...},
#   mdns: %{enabled: true, running: true, ...},
#   dhcpv4: %{enabled: false, running: false, ...},
#   dhcpv6: %{enabled: false, running: false, ...}
# }

# Get status of a specific service
YellowDog.get_service_status(:mdns)
# => %{
#   enabled: true,
#   running: true,
#   uptime: "45m 12s",
#   config: %{port: 5353, listen: "0.0.0.0"},
#   stats: %{total_entries: 150, active_entries: 120, expired_entries: 30}
# }

# Get service-specific statistics
YellowDog.get_service_stats(:mdns)
# => %{total_entries: 150, active_entries: 120, expired_entries: 30}

YellowDog.get_service_stats(:dhcpv4)
# => %{total_leases: 50, active_leases: 45, expired_leases: 5}

# Format status for console display
YellowDog.format_status(:all)
# Displays formatted status of all services

YellowDog.format_status(:mdns)
# Displays formatted status of mDNS service only
```

### Service-Specific APIs

Each protocol application provides its own public API for service-specific operations:

**mDNS Service (YellowDog.Mdns)**
```elixir
# Query cached mDNS messages
YellowDog.Mdns.query("printer.local")
YellowDog.Mdns.query("_http._tcp.local", :PTR)

# List all cached messages
YellowDog.Mdns.list_all()

# Get cache statistics
YellowDog.Mdns.stats()
# => %{total_entries: 150, active_entries: 120, expired_entries: 30}

# Clear cache
YellowDog.Mdns.clear_cache()

# Get service status
YellowDog.Mdns.status()
```

**DHCPv4 Service (YellowDog.Dhcpv4)**
```elixir
# List all leases
YellowDog.Dhcpv4.list_leases()

# Get a specific lease by MAC address
YellowDog.Dhcpv4.get_lease("00:11:22:33:44:55")

# Release a lease
YellowDog.Dhcpv4.release_lease("00:11:22:33:44:55")

# Get lease statistics
YellowDog.Dhcpv4.stats()
# => %{total_leases: 50, active_leases: 45, expired_leases: 5, pool_utilization: %{...}}

# Get service status
YellowDog.Dhcpv4.status()
```

**DHCPv6 Service (YellowDog.Dhcpv6)**
```elixir
# List all leases
YellowDog.Dhcpv6.list_leases()

# Get a specific lease by DUID and IAID
YellowDog.Dhcpv6.get_lease(duid, iaid)

# Release a lease
YellowDog.Dhcpv6.release_lease(duid, iaid)

# Get lease statistics
YellowDog.Dhcpv6.stats()
# => %{total_leases: 30, active_leases: 25, expired_leases: 5, pool_utilization: %{...}}

# Get service status
YellowDog.Dhcpv6.status()
```

**DNS Service (YellowDog.Dns)**
```elixir
# Get service status
YellowDog.Dns.status()

# Get DNS statistics (placeholder for future implementation)
YellowDog.Dns.stats()
```

### Status Display Format

When using `YellowDog.format_status(:all)`, the output is formatted as:

```
=== YellowDog Services Status ===

DNS: ENABLED | RUNNING
  Uptime: 1h 23m 45s
  Children: 3/3
  Memory: 12.5MB
  Config: 0.0.0.0:53

MDNS: ENABLED | RUNNING
  Uptime: 45m 12s
  Children: 2/2
  Memory: 5.2MB
  Cache: 120 active entries, 30 expired
  Config: 0.0.0.0:5353

DHCPV4: DISABLED | STOPPED
  Config: 0.0.0.0:67 (1 pools)

DHCPV6: DISABLED | STOPPED
  Config: :::547 (1 pools)
```

### Key Features

- **Real-time Status**: Check if services are enabled, running, and their uptime
- **Service Statistics**: Get detailed statistics for each service (cache entries, lease counts, etc.)
- **Configuration Display**: View active configuration for each service
- **Resource Monitoring**: Track memory usage and child process counts
- **Formatted Output**: Human-readable status display for console/logging

## CI/CD

### GitHub Actions Workflows

1. **CI** (`.github/workflows/ci.yml`):
   - Runs on push to all branches
   - Tests with Elixir 1.18 on OTP 27 and 28 (matrix testing)
   - Compiles with warnings-as-errors
   - Checks formatting with `mix format --check-formatted`
   - Credo linting currently disabled (TODO: re-enable)
   - Test coverage reporting currently disabled (TODO: re-enable)

2. **Docker Build** (`.github/workflows/docker.yml`):
   - Multi-architecture builds (x86_64, aarch64)
   - Uses Nix for reproducible builds
   - Pushes to GitHub Container Registry

3. **Alpine Docker** (`.github/workflows/alpine-docker.yml`):
   - Manual Alpine-based Docker builds
   - Multi-architecture support

4. **Release** (`.github/workflows/release.yml`):
   - Automated release builds

### Docker Images
- **Development**: `docker.io/gsmlg/yellowdogdns:dev` and `ghcr.io/gsmlg-dev/yellow-dog:dev`
- **Production**: Multi-arch images pushed to `ghcr.io/gsmlg-dev/yellow-dog`
- **Manual Builds**: Use `docker build -t yellowdogdns .` or `nix build .#docker`

## DNS Testing/Benchmarking

The DNS server can be benchmarked using:

```bash
# Create test queries file
echo "www.turku.fi A" > t.txt
echo "www.helsinki.fi A" >> t.txt

# Run DNS performance test
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 53
```

## Module Organization and Structure

### Module Naming Convention
All modules use the `YellowDog.<AppName>.ModuleName` pattern:
- Core modules: `YellowDog.Config`, `YellowDog.Server`, `YellowDog.Telemetry`
- Protocol modules: `YellowDog.Dns.*`, `YellowDog.Dhcpv4.*`, `YellowDog.Dhcpv6.*`, `YellowDog.Mdns.*`
- Infrastructure modules use their own namespacing: `Abyss.*`, `DNS.*`, `DHCP.*`

### Directory Structure
Directory structure mirrors the module hierarchy:
```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── dns.ex                 # YellowDog.Dns
├── handler/udp.ex       # YellowDog.Dns.Handler.UDP
└── view/                # YellowDog.Dns.View.* modules
    ├── acl.ex
    ├── cache.ex
    ├── resolver.ex
    └── zone_*.ex
```

### Application Architecture Note
The protocol-specific applications (yellow_dog_dns, yellow_dog_dhcpv4, yellow_dog_dhcpv6, yellow_dog_mdns) are configured as libraries rather than standalone applications. They do not have Application modules and are started/managed by the core YellowDog application.

Infrastructure applications (abyss, ex_dns, ex_dhcp) are also configured as library applications within the umbrella.

### Development Notes
- The project uses Git for version control with semantic release commit messages
- Configuration is centralized in the core `YellowDog` application with TOML file support
- The project follows Elixir/OTP conventions for umbrella projects with dot-notation module naming
- Protocol applications are configured as library applications started/managed by the core YellowDog application
- Test environment automatically adjusts configuration to avoid privileged port conflicts
- Use `direnv allow` or `devenv shell` to activate the development environment
- CI runs on all branch pushes with matrix testing on Elixir 1.18 and OTP 27/28
- Infrastructure libraries are integrated as umbrella applications with shared build paths
- All servers use the Abyss UDP library with proper transport options configuration

### Working with Umbrella Projects
- Run commands at umbrella root to affect all apps (e.g., `mix test`, `mix format`)
- Use `mix cmd` to run commands in each app directory: `mix cmd mix lint`
- Individual apps can be worked on independently by `cd apps/app_name`
- Mix aliases at umbrella level (test, lint, credo, dialyzer) use `mix cmd` to run across all apps
- Dependencies are shared via umbrella-level `mix.exs` for common libraries
- Infrastructure apps (abyss, ex_dns, ex_dhcp) use `in_umbrella: true` for cross-app dependencies

### Server Implementation Patterns
All protocol servers (DNS, DHCPv4, DHCPv6, mDNS) follow a consistent architectural pattern:

1. **Server Module** (`YellowDog.{App}.Server`)
   - GenServer-based implementation using Abyss UDP library
   - `start_link/1` with options parameter
   - `get_config/0` returning default configuration map
   - `build_server_config/1` handling transport options and service configuration
   - Proper IP address conversion from strings to tuples

2. **Handler Module** (`YellowDog.{App}.Handler`)
   - Implements `Abyss.Handler` behaviour
   - `handle_data/2`, `handle_error/2`, `handle_timeout/2` callbacks
   - Message parsing using protocol libraries (ex_dns, ex_dhcp)
   - Telemetry event emission for monitoring

3. **Supervisor Module** (`YellowDog.{App}.Supervisor`)
   - OTP supervisor with pre-start and post-start task support
   - Conditional service starting based on configuration
   - Proper child specifications for server processes
   - Integration with core YellowDog application orchestration

### Conditional Service Architecture
The core YellowDog application implements conditional service starting based on TOML configuration:
- Services are started/stopped based on `YellowDog.Config.service_enabled?(:service_name)` checks
- Each protocol application (DNS, DHCPv4, DHCPv6, mDNS) has a supervisor that's conditionally started
- Configuration is loaded via TOML files with test environment adjustments
- Services can be individually enabled/disabled without code changes
- The configuration manager starts first, followed by enabled service supervisors
- Test environment automatically disables services and uses non-privileged ports
- IP address conversion functions handle string-to-tuple transformation for transport options

## Code Quality

The project uses several tools for maintaining code quality:

- **Dialyzer**: Static type analysis with comprehensive warning flags (see `mix.exs`)
- **Credo**: Code linting (currently disabled in CI, will be re-enabled)
- **Formatter**: Automatic code formatting with `.formatter.exs`
- **Warnings as Errors**: Compilation treats warnings as errors in CI
- **Mix Aliases**: Available custom mix commands (see umbrella `mix.exs`)

## Build System

### Umbrella Configuration
- Main mix file: `mix.exs` (umbrella level)
- Application mix files: `apps/*/mix.exs` (individual applications)
- Shared dependencies defined at umbrella level
- Infrastructure apps use shared build paths: `build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`
- Release configuration includes `yellow_dog`, `yellow_dog_dns`, and `yellow_dog_telemetry` applications

### Dependencies

**Core Dependencies:**
- **abyss**: High-performance UDP server (now in umbrella, used across all protocol applications)
- **ex_dns**: DNS protocol handling (now in umbrella, used by DNS and mDNS applications)
- **ex_dhcp**: DHCP protocol implementation (now in umbrella, used by DHCPv4/DHCPv6 applications)
- **telemetry**: Metrics and observability (used by yellow_dog_telemetry package)
- **toml**: Configuration file parsing

**Web Console Dependencies:**
- **phoenix**: Web framework (~> 1.8.1)
- **phoenix_live_dashboard**: LiveView dashboard for monitoring (~> 0.8.3)
- **bandit**: HTTP server (~> 1.5)
- **telemetry_metrics**: Metrics aggregation (~> 1.0)
- **esbuild**: JavaScript bundler (dev only, ~> 0.10)
- **tailwind**: CSS framework (dev only, ~> 0.3)
- **heroicons**: Icon library (from GitHub)
- **swoosh**: Email composition library (~> 1.16)
- **gettext**: Internationalization (~> 0.20)

**Development & Testing:**
- **credo**: Code linting (development and test only)
- **machete**: Testing utilities (development and test only)
- **dialyxir**: Static type analysis (~> 1.0)