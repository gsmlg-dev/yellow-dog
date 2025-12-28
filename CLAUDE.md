# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yellow Dog DNS is a distributed DNS and DHCP server written in Erlang/Elixir using an umbrella project structure. The project has been completely refactored to use dot-notation module naming across all applications and now includes 10 applications total - 7 core YellowDog applications and 3 infrastructure libraries.

### Applications (10 total)

**Core YellowDog Applications:**
- **YellowDog** - Core application with configuration management and orchestration
- **YellowDog.Telemetry** - Centralized telemetry and metrics functionality
- **YellowDog.Dns** - DNS functionality including name resolution, zones, and views
- **YellowDog.Dhcpv4** - DHCPv4 protocol implementation (production-ready with full lease management)
- **YellowDog.Dhcpv6** - DHCPv6 protocol implementation (production-ready with full lease management)
- **YellowDog.Mdns** - mDNS responder with service discovery and registration (production-ready)
- **YellowDogConsole** - Phoenix LiveView web console with DaisyUI (production-ready)

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

### E2E Testing
```bash
# Run all E2E tests (starts services with auto-selected ports)
mix test.e2e

# Run E2E tests for specific services
mix test.e2e.dns       # DNS server E2E tests
mix test.e2e.mdns      # mDNS server E2E tests
mix test.e2e.dhcpv4    # DHCPv4 server E2E tests
mix test.e2e.dhcpv6    # DHCPv6 server E2E tests
```

**E2E Test Structure:**
- `e2e_test/` - E2E test directory at umbrella root
- `e2e_test/support/` - Shared test helpers
  - `service_helper.ex` - Service lifecycle management (start/stop servers)
  - `dns_client.ex` - DNS query helper using ex_dns library
  - `dhcp_client.ex` - DHCP message helper using ex_dhcp library
- `e2e_test/*_e2e_test.exs` - E2E test files for each service

**E2E Test Patterns:**
- Services start with `port: 0` for auto-selection (CI-friendly)
- mDNS uses unicast to loopback in CI (no multicast)
- Each test file has `setup` callback to start service and `on_exit` for cleanup
- Tests verify real protocol behavior (DNS queries, DHCP handshakes)

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
mix assets.build       # Build assets (tailwind + bun)
mix assets.deploy      # Build minified assets for production

# Or use Bun directly
bun run build          # Development build with sourcemaps
bun run build:prod     # Production build (minified)
bun run watch          # Watch mode for development
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
- **Important**: Use `DNS.to_iodata/1` for serialization (not `DNS.Message.to_iodata/1`)

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
- **Purpose**: Multicast DNS responder with service discovery and registration
- **Dependencies**: `ex_dns`, `abyss`, `yellow_dog_telemetry`
- **Directory Structure**: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/`
- **Key Modules**:
  - `YellowDog.Mdns.Server` - mDNS server using Abyss UDP library
  - `YellowDog.Mdns.Handler` - mDNS message handler implementing Abyss.Handler behaviour
  - `YellowDog.Mdns.Supervisor` - mDNS supervisor with pre/post-start tasks
  - `YellowDog.Mdns.ServiceRegistry` - GenServer for service registration with ETS storage
  - `YellowDog.Mdns.Responder` - Query responder for registered services
  - `YellowDog.Mdns.Monitor` - Network activity monitoring
- **Features**:
  - Full mDNS responder implementation (listens and responds to queries)
  - Service registration and announcement with PTR, SRV, TXT, A/AAAA records
  - Multicast DNS on 224.0.0.251:5353
  - .local domain support
  - ETS-based service registry with TTL support
  - API for service registration, updates, and removal
  - Service discovery with query/response handling
  - Network activity monitoring and statistics
  - Periodic service announcements
  - TOML-based configuration with services file support
  - Comprehensive telemetry events for monitoring
- **Configuration**: Multicast address, port, and services configured via TOML
- **Status**: Production-ready with full responder and service discovery

**YellowDogConsole (Web Console)**
- **Location**: `apps/yellow_dog_console/`
- **Purpose**: Phoenix LiveView-based web console for management and monitoring
- **Dependencies**: `phoenix`, `phoenix_live_dashboard`, `bandit`, `telemetry_metrics`, `gettext`, DaisyUI 5.0.35, Tailwind CSS 4.1.11, Bun (JavaScript bundler)
- **Directory Structure**: `apps/yellow_dog_console/lib/yellow_dog/console/`
- **Key Modules**:
  - `YellowDog.Console.Application` - Web application supervisor
  - `YellowDog.Console.Endpoint` - Phoenix endpoint
  - `YellowDog.Console.Router` - Web routes
  - `YellowDog.Console.Layouts` - Phoenix 1.8 function component layouts (root, app, navbar, sidebar)
  - `YellowDog.Console.CoreComponents` - DaisyUI component library (12 reusable components)
  - `YellowDog.Console.DashboardLive` - Service dashboard with real-time status
  - `YellowDog.Console.MdnsLive.*` - mDNS management pages (index, services, discovery, monitor)
  - `YellowDog.Console.Dhcpv4Live.*` - DHCPv4 management pages (index, leases, pools)
  - `YellowDog.Console.Dhcpv6Live.*` - DHCPv6 management pages (index, leases, pools)
  - `YellowDog.Console.Telemetry` - Telemetry metrics for web interface
- **Features**:
  - Modern DaisyUI component library with 12 reusable components (stat, badge, card, modal, table, progress, status indicators)
  - Dark mode support with localStorage persistence
  - Responsive design (mobile → tablet → desktop)
  - Real-time service monitoring and status updates
  - mDNS service discovery and management
  - DHCPv4/DHCPv6 lease management and pool configuration
  - Data tables with filtering, sorting, and actions
  - Modal forms for service configuration
  - Phoenix 1.8 function component architecture
- **Status**: Production-ready with full UI transformation

### Web Console Asset Building

The web console uses **Bun** for JavaScript bundling (migrated from esbuild):

**Build System:**
- JavaScript assets are built using Bun (fast, all-in-one JavaScript runtime)
- Phoenix dependencies (phoenix, phoenix_html, phoenix_live_view) are symlinked from `deps/` to `node_modules/`
- Build outputs go to `priv/static/assets/`
- Development builds include sourcemaps for debugging
- Production builds are minified and optimized

**Key Files:**
- `package.json` - Bun build scripts and configuration
- `bunfig.toml` - Bun-specific configuration
- `node_modules/` - Symlinks to Phoenix deps (auto-created by `mix assets.setup`)
- `assets/js/app.js` - Entry point for JavaScript bundle

**Build Commands:**
```bash
# From apps/yellow_dog_console
bun run build       # Development: 255KB with sourcemaps
bun run build:prod  # Production: 136KB minified
bun run watch       # Watch mode with hot reload

# Via Mix aliases (from project root)
mix assets.setup    # Create symlinks to Phoenix deps
mix assets.build    # Tailwind + Bun build
mix assets.deploy   # Production build + phx.digest
```

**How It Works:**
1. `mix assets.setup` creates `node_modules/` with symlinks to Phoenix packages in `deps/`
2. Bun resolves imports from symlinked packages (no npm install needed)
3. Assets are bundled as ESM modules targeting modern browsers
4. Phoenix serves built assets from `priv/static/assets/`

### Web Console Development Patterns

The web console follows Phoenix 1.8 best practices with DaisyUI for UI components:

**Component Architecture:**
- Use `use YellowDog.Console, :html` for function components
- Use `use YellowDog.Console, :live_view` for LiveView modules
- Phoenix 1.8 layout system: Single `root.html.heex` template in `layouts/` directory, loaded via `embed_templates "layouts/*"` in `layouts.ex`
- Function components (app, navbar, sidebar, flash) defined in `layouts.ex`
- Components defined in `YellowDog.Console.CoreComponents` are automatically imported

**Available DaisyUI Components:**
```elixir
# Core components available in all views
<.stat title="..." value="..." desc="..." />
<.badge color="success|error|warning|info" size="sm|md|lg" />
<.card title="..."></:actions></.card>
<.modal id="..." title="...">form content</.modal>
<.table id="..." rows={@items} zebra hover>
  <:col :let={item} label="Name"><%= item.name %></:col>
  <:action :let={item}><button>Edit</button></:action>
</.table>
<.progress value={50} color="success|error|warning|info" />
<.progress_radial value={75} size="lg" color="primary" />
<.status_indicator status="running|stopped|error" label="..." pulse />
<.toast type="info|success|error|warning">Message</.toast>
<.loading size="sm|md|lg" />
```

**Dark Mode Implementation:**
- Theme toggle in navbar uses JavaScript hook with localStorage
- Theme persists across page reloads
- Attribute `data-theme="light"` or `data-theme="dark"` on `<body>`
- Hook: `phx-hook="ThemeToggle"` in `assets/js/app.js`

**LiveView Patterns:**
- Subscribe to PubSub topics in `mount/3` when `connected?(socket)`
- Use `handle_info/2` for real-time updates
- Implement filtering with `phx-click` and socket assigns
- Modal visibility controlled by `@show_form` assign
- Use `<dialog>` element with `modal modal-open` classes

**Responsive Design:**
- Drawer pattern for sidebar: `<div class="drawer lg:drawer-open">`
- Stats: `stats-vertical lg:stats-horizontal`
- Grid: `grid-cols-1 md:grid-cols-2 xl:grid-cols-3`
- Always test mobile → tablet → desktop breakpoints

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
# Register a new service
YellowDog.Mdns.register_service(%{
  name: "My Web Server",
  type: "_http._tcp",
  port: 8080,
  domain: "local",
  txt: %{"path" => "/", "version" => "1.0"}
})

# Update service information
YellowDog.Mdns.update_service(service_id, %{port: 8081})

# Unregister a service
YellowDog.Mdns.unregister_service(service_id)

# List all registered services
YellowDog.Mdns.list_services()

# Get service by ID
YellowDog.Mdns.get_service(service_id)

# Query for services by type
YellowDog.Mdns.query_services("_http._tcp.local")

# Get registry statistics
YellowDog.Mdns.stats()
# => %{total: 10, enabled: 8, disabled: 2, registered: 5, from_file: 3}

# Get network statistics
YellowDog.Mdns.network_stats()
# => %{total_responses: 150, total_queries: 200, active_services: 8, unique_hosts: 15}

# Get service status
YellowDog.Mdns.status()
# => %{running: true, mode: :responder, registered_services: 8, discovered_services: 12}
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
- **bun**: JavaScript bundler and runtime (for asset building)
- **tailwind**: CSS framework (dev only, ~> 0.3)
- **heroicons**: Icon library (from GitHub)
- **swoosh**: Email composition library (~> 1.16)
- **gettext**: Internationalization (~> 0.20)

**Development & Testing:**
- **credo**: Code linting (development and test only)
- **machete**: Testing utilities (development and test only)
- **dialyxir**: Static type analysis (~> 1.0)
- Never disable any job in ci.yml

## Active Technologies
- Elixir 1.18 / OTP 27-28 + Abyss (UDP server), ex_dns (DNS protocol), Phoenix LiveView 1.0, DaisyUI 5.0 (001-dns-service)
- ETS tables for caching, Agent for configuration (001-dns-service)
- Elixir 1.18 with OTP 27/28 + ExUnit, ex_dns (DNS protocol), ex_dhcp (DHCP protocol), abyss (UDP transport) (001-e2e-service-tests)
- N/A (in-memory test data only) (001-e2e-service-tests)
- Elixir 1.18 / OTP 27-28 + Phoenix LiveView 1.0, ex_dns (in_umbrella), ex_dhcp (in_umbrella), DaisyUI 5.0 (001-service-diagnostics)
- LiveView assigns (session-scoped, ETS not required) (001-service-diagnostics)
- Elixir 1.18 / OTP 27-28 + `:telemetry` (already present), `yellow_dog_telemetry` (in umbrella) (001-telemetry-logging)
- N/A (in-memory telemetry events) (001-telemetry-logging)
- Elixir 1.18 / OTP 27-28 + `:telemetry` (~> 1.0), `yellow_dog_telemetry` (umbrella) (001-complete-logger-telemetry-migration)
- ETS tables for caching, Agent for configuration (no changes) (001-complete-logger-telemetry-migration)
- Elixir 1.18 / OTP 27+ + Phoenix LiveView 1.0, DaisyUI 5.0, YellowDog.Telemetry (in_umbrella) (001-realtime-logs-page)
- N/A (in-memory log buffer in LiveView assigns, no persistence required) (001-realtime-logs-page)
- Elixir 1.18 / OTP 27-28 + Phoenix LiveView 1.0, DaisyUI 5.0, Heroicons (001-process-map)
- N/A (in-memory process introspection only) (001-process-map)

## Recent Changes
- 001-dns-service: Added Elixir 1.18 / OTP 27-28 + Abyss (UDP server), ex_dns (DNS protocol), Phoenix LiveView 1.0, DaisyUI 5.0
