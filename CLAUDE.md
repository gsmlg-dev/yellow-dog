# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yellow Dog DNS is a distributed DNS and DHCP server written in Erlang/Elixir using an umbrella project structure. The project has been completely refactored to use dot-notation module naming across all applications:

- **YellowDog** - Core application with configuration management and orchestration
- **YellowDog.Dns** - DNS functionality including name resolution, zones, and views
- **YellowDog.Dhcpv4** - DHCPv4 protocol implementation
- **YellowDog.Dhcpv6** - DHCPv6 protocol implementation
- **YellowDog.Mdns** - mDNS (multicast DNS) functionality

All modules follow the `YellowDog.<AppName>.ModuleName` pattern, and directory structures reflect the module hierarchy (e.g., `apps/yellow_dog_dns/lib/yellow_dog/dns/`).

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
mix app.start yellow_dog_core
mix app.start yellow_dog_dns
```

### Testing
```bash
# Run all tests
mix test

# Run tests for specific app
mix test apps/yellow_dog_dns

# Run tests for specific path
mix test path/to/test_file.exs

# Batch fix test failures using the custom command
/elixir-fix-tests-batch [test_path]
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
```

### Clean Build
```bash
# Clean all compiled artifacts
mix clean

# Clean and rebuild everything
mix clean && mix compile
```

## Architecture

This is an Elixir umbrella project with 5 applications:

### YellowDog (Core Application)
- **Location**: `apps/yellow_dog_core/`
- **Purpose**: Configuration management, orchestration, and public API
- **Application Module**: `YellowDog.Application`
- **Key Modules**:
  - `YellowDog.Config` - Configuration management
  - `YellowDog.ServerConfig` - Server configuration
  - `YellowDog.Server` - Main server orchestration
  - `YellowDog.Telemetry` - Metrics and observability
  - `YellowDog` - Public API (exposed through `apps/yellow_dog_core/lib/yellow_dog.ex`)

### YellowDog.Dns (DNS Application)
- **Location**: `apps/yellow_dog_dns/`
- **Purpose**: DNS protocol handling and name resolution
- **Application Module**: `YellowDog.Dns.Application`
- **Dependencies**: `ex_dns`, `abyss`, `telemetry`
- **Directory Structure**: `apps/yellow_dog_dns/lib/yellow_dog/dns/`
- **Key Modules**:
  - `YellowDog.Dns.NameResolver` - DNS name resolution
  - `YellowDog.Dns.ViewManager` - DNS view management
  - `YellowDog.Dns.View` - DNS views and zones
  - `YellowDog.Dns.Handler.UDP` - UDP DNS packet handling
  - **View Submodules**: `YellowDog.Dns.View.ACL`, `YellowDog.Dns.View.Cache`, `YellowDog.Dns.View.Resolver`, `YellowDog.Dns.View.ZoneManager`, etc.

### YellowDog.Dhcpv4 (DHCPv4 Application)
- **Location**: `apps/yellow_dog_dhcpv4/`
- **Purpose**: DHCPv4 protocol implementation
- **Application Module**: `YellowDog.Dhcpv4.Application`
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Directory Structure**: `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/`
- **Status**: Basic structure created, implementation pending

### YellowDog.Dhcpv6 (DHCPv6 Application)
- **Location**: `apps/yellow_dog_dhcpv6/`
- **Purpose**: DHCPv6 protocol implementation
- **Application Module**: `YellowDog.Dhcpv6.Application`
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Directory Structure**: `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/`
- **Status**: Basic structure created, implementation pending

### YellowDog.Mdns (mDNS Application)
- **Location**: `apps/yellow_dog_mdns/`
- **Purpose**: Multicast DNS functionality
- **Application Module**: `YellowDog.Mdns.Application`
- **Dependencies**: `ex_dns`, `abyss`, `telemetry`
- **Directory Structure**: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/`
- **Status**: Basic structure created, implementation pending

### Inter-Application Dependencies
- All applications depend on `YellowDog` for configuration
- `YellowDog.Dns` and `YellowDog.Mdns` use `ex_dns` for DNS protocol handling
- `YellowDog.Dhcpv4` and `YellowDog.Dhcpv6` use `dhcp_ex` for DHCP protocol handling
- All applications use `abyss` as the UDP server
- All applications use `telemetry` for observability

## Configuration

Configuration is centralized in the core `YellowDog.Config` module:

```elixir
# Get configuration values
YellowDog.get_config(:key)
YellowDog.get_all_config()

# Public API access
YellowDog.start_link()
YellowDog.banner()
```

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

### Directory Structure
Directory structure mirrors the module hierarchy:
```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── dns.ex                 # YellowDog.Dns
├── application.ex        # YellowDog.Dns.Application
├── handler/udp.ex       # YellowDog.Dns.Handler.UDP
└── view/                # YellowDog.Dns.View.* modules
    ├── acl.ex
    ├── cache.ex
    ├── resolver.ex
    └── zone_*.ex
```

### Development Notes
- The project uses Git for version control
- Configuration is centralized in the core `YellowDog` application
- The project follows Elixir/OTP conventions for umbrella projects
- Applications can be started independently for testing and development
- Use `direnv allow` or `devenv shell` to activate the development environment
- CI runs on all branch pushes, not just main/dev branches
- Several CI features are temporarily disabled (credo, coverage) but will be re-enabled

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
- Release configuration includes `yellow_dog_core` and `yellow_dog_dns` applications

### Dependencies
- **abyss**: High-performance UDP server (used across all applications)
- **ex_dns**: DNS protocol handling (used by DNS and mDNS applications)
- **dhcp_ex**: DHCP protocol implementation (used by DHCPv4/DHCPv6 applications)
- **telemetry**: Metrics and observability (used across all applications)
- **credo**: Code linting (development and test only)
- **toml**: Configuration file parsing