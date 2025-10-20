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

# Start specific applications
mix app.start yellow_dog
mix app.start yellow_dog_dns

# Start the Phoenix web console (development mode)
cd apps/yellow_dog_console
mix phx.server
# Then visit http://localhost:4000
```

### Testing
```bash
# Run all tests
mix test

# Run tests for specific app
mix test apps/yellow_dog_dns

# Run tests for specific path
mix test path/to/test_file.exs

# Run tests for specific app only
MIX_ENV=test mix test apps/yellow_dog_dhcpv4

# Run single test file
mix test apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/handler_test.exs
```

### Code Formatting
```bash
# Format all code according to .formatter.exs configuration
mix format

# The formatter covers mix.exs, config/*.exs, and all apps/* subdirectories
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
- **Features**: Complete DHCPv4 protocol support (DISCOVER, OFFER, REQUEST, ACK, NAK), IPv4 broadcast handling, telemetry events

**YellowDog.Dhcpv6 (DHCPv6 Application)**
- **Location**: `apps/yellow_dog_dhcpv6/`
- **Purpose**: DHCPv6 protocol implementation with full server functionality
- **Dependencies**: `ex_dhcp`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/`
- **Key Modules**:
  - `YellowDog.Dhcpv6.Server` - DHCPv6 server using Abyss UDP library
  - `YellowDog.Dhcpv6.Handler` - DHCPv6 message handler implementing Abyss.Handler behaviour
  - `YellowDog.Dhcpv6.Supervisor` - DHCPv6 supervisor with pre/post-start tasks
- **Features**: Complete DHCPv6 protocol support (SOLICIT, ADVERTISE, REQUEST, RENEW, REBIND), IPv6 multicast support, DUID-based client identification

**YellowDog.Mdns (mDNS Application)**
- **Location**: `apps/yellow_dog_mdns/`
- **Purpose**: Multicast DNS functionality
- **Dependencies**: `ex_dns`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/`
- **Status**: Basic structure created, implementation pending

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