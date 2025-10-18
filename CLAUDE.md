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

## Architecture

This is an Elixir umbrella project with 5 applications:

### YellowDogCore (Core Application)
- **Location**: `apps/yellow_dog_core/`
- **Purpose**: Configuration management, orchestration, and public API
- **Application Module**: `YellowDogCore.Application`
- **Key Modules**:
  - `YellowDogCore.Config` - Configuration management
  - `YellowDogCore.ServerConfig` - Server configuration
  - `YellowDogCore.Server` - Main server orchestration
  - `YellowDogCore.Telemetry` - Metrics and observability
  - `YellowDog` - Public API (exposed through `apps/yellow_dog_core/lib/yellow_dog.ex`)

### YellowDogDns (DNS Application)
- **Location**: `apps/yellow_dog_dns/`
- **Purpose**: DNS protocol handling and name resolution
- **Application Module**: `YellowDogDns.Application`
- **Dependencies**: `ex_dns`, `abyss`, `telemetry`
- **Key Modules**:
  - `YellowDogDns.NameResolver` - DNS name resolution
  - `YellowDogDns.ViewManager` - DNS view management
  - `YellowDogDns.View` - DNS views and zones
  - `YellowDogDns.Handler.UDP` - UDP DNS packet handling

### YellowDogDhcpv4 (DHCPv4 Application)
- **Location**: `apps/yellow_dog_dhcpv4/`
- **Purpose**: DHCPv4 protocol implementation
- **Application Module**: `YellowDogDhcpv4.Application`
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Status**: Basic structure created, implementation pending

### YellowDogDhcpv6 (DHCPv6 Application)
- **Location**: `apps/yellow_dog_dhcpv6/`
- **Purpose**: DHCPv6 protocol implementation
- **Application Module**: `YellowDogDhcpv6.Application`
- **Dependencies**: `dhcp_ex`, `abyss`, `telemetry`
- **Status**: Basic structure created, implementation pending

### YellowDogMdns (mDNS Application)
- **Location**: `apps/yellow_dog_mdns/`
- **Purpose**: Multicast DNS functionality
- **Application Module**: `YellowDogMdns.Application`
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

## Development Notes

- The project uses Git for version control
- Configuration is centralized in the core `YellowDogCore` application
- The project follows Elixir/OTP conventions for umbrella projects
- Module names follow the pattern `YellowDog<AppName>.ModuleName`
- Applications can be started independently for testing and development
- Use `direnv allow` or `devenv shell` to activate the development environment
- CI runs on all branch pushes, not just main/dev branches
- Several CI features are temporarily disabled (credo, coverage) but will be re-enabled

## Code Quality

The project uses several tools for maintaining code quality:

- **Dialyzer**: Static type analysis with comprehensive warning flags
- **Credo**: Code linting (currently disabled in CI, will be re-enabled)
- **Formatter**: Automatic code formatting with `.formatter.exs`
- **Warnings as Errors**: Compilation treats warnings as errors in CI