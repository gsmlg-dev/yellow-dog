# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yellow Dog DNS is a distributed DNS and DHCP server written in Erlang/Elixir using an umbrella project structure. The project has been refactored into 5 separate applications:

- **YellowDogCore** - Core application with configuration management and orchestration
- **YellowDogDns** - DNS functionality including name resolution, zones, and views
- **YellowDogDhcpv4** - DHCPv4 protocol implementation
- **YellowDogDhcpv6** - DHCPv6 protocol implementation
- **YellowDogMdns** - mDNS (multicast DNS) functionality

## Development Environment Setup

This project uses [devenv](https://devenv.sh) for development environment management:

```bash
# Activate the development environment
direnv allow  # or use devenv shell

# The environment includes:
# - Elixir 1.16.1 with OTP 26
# - Git, figlet, lolcat, watchman, inotify-tools
# - JavaScript support with pnpm and bun
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
```

## Architecture

This is an Elixir umbrella project with 5 applications:

### YellowDogCore (Core Application)
- **Location**: `apps/yellow_dog_core/`
- **Purpose**: Configuration management, orchestration, and public API
- **Key Modules**:
  - `YellowDogCore.Config` - Configuration management
  - `YellowDogCore.ServerConfig` - Server configuration
  - `YellowDogCore.Server` - Main server orchestration
  - `YellowDogCore.Telemetry` - Metrics and observability

### YellowDogDns (DNS Application)
- **Location**: `apps/yellow_dog_dns/`
- **Purpose**: DNS protocol handling and name resolution
- **Dependencies**: `ex_dns`, `abyss`, `telemetry`
- **Key Modules**:
  - `YellowDogDns.NameResolver` - DNS name resolution
  - `YellowDogDns.ViewManager` - DNS view management
  - `YellowDogDns.View` - DNS views and zones
  - `YellowDogDns.Handler.UDP` - UDP DNS packet handling

### YellowDogDhcpv4 (DHCPv4 Application)
- **Location**: `apps/yellow_dog_dhcpv4/`
- **Purpose**: DHCPv4 protocol implementation
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Status**: Basic structure created, implementation pending

### YellowDogDhcpv6 (DHCPv6 Application)
- **Location**: `apps/yellow_dog_dhcpv6/`
- **Purpose**: DHCPv6 protocol implementation
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Status**: Basic structure created, implementation pending

### YellowDogMdns (mDNS Application)
- **Location**: `apps/yellow_dog_mdns/`
- **Purpose**: Multicast DNS functionality
- **Dependencies**: `ex_dns`, `abyss`, `telemetry`
- **Status**: Basic structure created, implementation pending

### Inter-Application Dependencies
- All applications depend on `YellowDogCore` for configuration
- `YellowDogDns` and `YellowDogMdns` use `ex_dns` for DNS protocol handling
- `YellowDogDhcpv4` and `YellowDogDhcpv6` use `dhcp_ex` for DHCP protocol handling
- All applications use `abyss` as the UDP server
- All applications use `telemetry` for observability

## Configuration

Configuration is centralized in the core `YellowDogCore.Config` module:

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

1. **Elixir CI** (`.github/workflows/elixir.yml`):
   - Runs on push to `main`/`dev` branches and PRs to `main`
   - Tests with Elixir 1.16.1 and OTP 26
   - Builds and pushes Docker images for `dev` branch

2. **Docker Build** (`.github/workflows/docker.yml`):
   - Multi-architecture builds (x86_64, aarch64)
   - Uses Nix for reproducible builds
   - Pushes to GitHub Container Registry

### Docker Images
- **Development**: `docker.io/gsmlg/yellowdogdns:dev` and `ghcr.io/gsmlg-dev/yellow-dog:dev`
- **Production**: Multi-arch images pushed to `ghcr.io/gsmlg-dev/yellow-dog`

## DNS Testing/Benchmarking

The DNS server can be benchmarked using:

```bash
# Create test queries file
echo "www.turku.fi A" > t.txt
echo "www.helsinki.fi A" >> t.txt

# Run DNS performance test
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 53
```

## Development Notes

- The project uses Git for version control
- Configuration is centralized in the core `YellowDogCore` application
- The project follows Elixir/OTP conventions for umbrella projects
- Module names follow the pattern `YellowDog<AppName>.ModuleName`
- Use the provided batch test fixing command for efficient test maintenance
- Applications can be started independently for testing and development