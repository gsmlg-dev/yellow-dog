<!--
Sync Impact Report - Constitution v1.3.0
========================================
Version Change: 1.2.0 → 1.3.0 (MINOR bump)

Reason: Added new mandatory Logging Standards requiring all logging to use yellow_dog_telemetry
with telemetry-attached handlers instead of direct Logger calls.

Modified Principles:
- Telemetry Standards: Expanded with new Logging Standards subsection
- Prohibited Practices: Added rule #13 prohibiting direct Logger calls

Added Sections:
- ## Telemetry Standards > ### Logging Standards (NEW)
  - MANDATORY: All logging via yellow_dog_telemetry
  - Prohibited: Direct Logger.info/warn/error/debug calls
  - Implementation patterns for telemetry-based logging
  - Logger handler attachment examples

Changes Summary:
- Added explicit requirement for yellow_dog_telemetry as the only permitted logging mechanism
- Prohibited direct Logger module usage for application logging
- Provided telemetry event emission patterns with examples
- Provided Logger handler attachment patterns for log output
- Updated Prohibited Practices with new logging rule
- Rationale: Centralized observability, structured logging, consistent metrics

Previous Changes (v1.2.0):
- Added explicit requirement for :http_fetch as the only permitted HTTP client
- Prohibited Tesla, HTTPoison, Finch, and other HTTP client libraries

Templates Requiring Updates:
⚠ .specify/templates/plan-template.md - Does not exist yet
⚠ .specify/templates/spec-template.md - Does not exist yet
⚠ .specify/templates/tasks-template.md - Does not exist yet
⚠ .specify/templates/commands/*.md - Does not exist yet

Follow-up TODOs:
- Update CLAUDE.md with logging standard
- Audit existing code for direct Logger usage and migrate to telemetry
- Add telemetry handler examples to yellow_dog_telemetry documentation
- Ensure CI checks for prohibited Logger calls (optional linting rule)

Ratification Date: 2025-11-07 (original)
Last Amended: 2025-12-22
-->

# Yellow Dog DNS - Project Constitution

## Project Overview

Yellow Dog DNS is a distributed DNS and DHCP server written in Erlang/Elixir using an umbrella project structure. The project provides DNS, DHCPv4, DHCPv6, and mDNS services with a Phoenix LiveView-based web interface for management and monitoring.

## Core Architecture Principles

### 1. Umbrella Project Structure

The project is organized as an Elixir umbrella with 10 applications:

**Core YellowDog Applications (7):**
- `yellow_dog` - Core application with configuration management and orchestration
- `yellow_dog_telemetry` - Centralized telemetry and metrics functionality
- `yellow_dog_dns` - DNS functionality including name resolution, zones, and views
- `yellow_dog_dhcpv4` - DHCPv4 protocol implementation (production-ready)
- `yellow_dog_dhcpv6` - DHCPv6 protocol implementation (production-ready)
- `yellow_dog_mdns` - mDNS responder with service discovery (production-ready)
- `yellow_dog_console` - Phoenix LiveView web console with DaisyUI (production-ready)

**Infrastructure Libraries (3):**
- `abyss` - High-performance pure Elixir UDP server library
- `ex_dns` - Pure Elixir DNS protocol library (resource records, zone management)
- `ex_dhcp` - Pure Elixir DHCP protocol library (DHCPv4/v6 message handling)

### 2. Module Naming Convention

**MANDATORY:** All modules follow the `YellowDog.<AppName>.ModuleName` pattern:
- Core: `YellowDog.Config`, `YellowDog.Server`, `YellowDog.Telemetry`
- Protocol: `YellowDog.Dns.*`, `YellowDog.Dhcpv4.*`, `YellowDog.Dhcpv6.*`, `YellowDog.Mdns.*`
- Infrastructure: `Abyss.*`, `DNS.*`, `DHCP.*` (own namespacing)

**Directory structure MUST mirror module hierarchy:**
```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── dns.ex                 # YellowDog.Dns
├── handler/udp.ex         # YellowDog.Dns.Handler.UDP
└── view/                  # YellowDog.Dns.View.* modules
```

## Protocol Implementation Standards

### DNS Protocol (`apps/ex_dns`)

**MANDATORY RULES:**
1. All DNS protocol types, records, and message handling MUST be defined in `apps/ex_dns`
2. DNS message serialization MUST use `DNS.to_iodata/1` (NOT `DNS.Message.to_iodata/1`)
3. The library supports 20+ record types and DNSSEC
4. Zone management and parsing is centralized in this library

**Usage in yellow_dog_dns:**
- Import protocol types from `ex_dns`
- Implement business logic (resolution, caching, forwarding) in `yellow_dog_dns`
- Use `DNS.Message`, `DNS.Zone`, `DNS.ResourceRecordType`, `DNS.Parameter`

### DHCP Protocol (`apps/ex_dhcp`)

**MANDATORY RULES:**
1. All DHCP protocol types, options, and message handling MUST be defined in `apps/ex_dhcp`
2. Support both DHCPv4 and DHCPv6 protocols
3. Binary serialization and RFC-compliant message handling
4. Secure random generation for transaction IDs

**Usage in yellow_dog_dhcpv4/dhcpv6:**
- Import protocol types from `ex_dhcp`
- Implement lease management, address pools, and server logic in protocol apps
- Use `DHCPv4.Message`, `DHCPv6.Message`, `DHCP.Parameter`

## Transport Layer Standards

### UDP Transport (`apps/abyss`)

**MANDATORY RULE:** ALL UDP servers MUST use the Abyss library.

**Prohibited:**
- ❌ Direct `:gen_udp` usage in protocol applications
- ❌ Custom UDP socket handling
- ❌ Third-party UDP libraries

**Required Features:**
- Connection pooling
- Rate limiting
- Telemetry event emission
- Broadcast mode support
- Handler behaviour implementation

**Implementation Pattern:**
```elixir
defmodule YellowDog.<Protocol>.Server do
  use GenServer

  def start_link(opts) do
    # Build Abyss.ServerConfig
    config = build_server_config(opts)
    Abyss.Server.start_link(config)
  end

  defp build_server_config(opts) do
    %Abyss.ServerConfig{
      handler: YellowDog.<Protocol>.Handler,
      transport: Abyss.Transport.UDP,
      transport_options: [
        ip: parse_ip_address(opts[:listen]),
        port: opts[:port]
      ]
    }
  end
end

defmodule YellowDog.<Protocol>.Handler do
  @behaviour Abyss.Handler

  def handle_data(data, client_info, state) do
    # Protocol-specific handling
  end
end
```

### TCP Transport (DNS only)

**MANDATORY RULE:** DNS TCP and TLS connections MUST use `:thousand_island`.

**Prohibited:**
- ❌ Direct `:gen_tcp` usage
- ❌ Custom TCP socket handling
- ❌ Other TCP libraries

**Usage:**
- DNS queries over TCP (for large responses)
- DNS over TLS (DoT)
- Connection management and pooling

### HTTP Transport

**MANDATORY RULE:** HTTP/HTTPS requests MUST use `:http_fetch`.

**Prohibited:**
- ❌ Tesla HTTP client
- ❌ HTTPoison
- ❌ Finch
- ❌ Mint (directly)
- ❌ Direct `:httpc` usage
- ❌ Other HTTP client libraries

**Required Usage:**
- External API calls
- HTTP-based service integrations
- Webhook requests
- DNS-over-HTTPS (DoH) queries
- DHCP vendor option retrieval
- File uploads/downloads

**Implementation Patterns:**

```elixir
# Basic GET request (promise-based)
{:ok, response} =
  HTTP.fetch("https://api.example.com/endpoint")
  |> HTTP.Promise.await()

# GET with headers and timeout
{:ok, response} =
  HTTP.fetch("https://api.example.com/data", [
    method: "GET",
    headers: %{"Authorization" => "Bearer token"},
    options: [timeout: 5000]
  ])
  |> HTTP.Promise.await()

# POST with JSON body
{:ok, response} =
  HTTP.fetch("https://api.example.com/resource", [
    method: "POST",
    headers: %{"Content-Type" => "application/json"},
    body: Jason.encode!(%{data: "value"})
  ])
  |> HTTP.Promise.await()

# Handle responses using browser-like API
case response do
  %{ok: true, status: 200} ->
    {:ok, data} = HTTP.Response.json(response)
    {:ok, data}
  %{status: status} ->
    {:error, {:http_error, status}}
end

# PUT/DELETE/PATCH
HTTP.fetch(url, [method: "PUT", body: payload])
HTTP.fetch(url, [method: "DELETE"])
HTTP.fetch(url, [method: "PATCH", body: patch_data])

# Form data with file upload
form = HTTP.FormData.new()
       |> HTTP.FormData.append_field("name", "value")
       |> HTTP.FormData.append_file("file", "doc.pdf", File.stream!("doc.pdf"))

HTTP.fetch("https://api.example.com/upload", [
  method: "POST",
  body: form
])

# Unix domain socket (Docker API, systemd)
HTTP.fetch("http://localhost/containers/json", [
  unix_socket: "/var/run/docker.sock"
])
```

**Response Methods:**
- `HTTP.Response.text(response)` - Get response as text string
- `HTTP.Response.json(response)` - Parse JSON: `{:ok, data} | {:error, reason}`
- `HTTP.Response.arrayBuffer(response)` - Get raw binary
- `HTTP.Response.write_to(response, path)` - Save to file

**Advanced Features:**
- **Request Cancellation**: Use `HTTP.AbortController` for cancellable requests
- **Promise Chaining**: Use `.then()` for transformations before awaiting
- **Telemetry**: Automatic `:http_fetch` events for monitoring
- **Streaming**: Efficient file uploads via streams

**Rationale:**
- **Zero dependencies** - Only OTP built-in modules (`:httpc`, `:ssl`, `:public_key`)
- **Browser-like API** - Familiar Fetch API pattern (~85% compatibility)
- **Telemetry built-in** - Automatic request monitoring
- **Promise-based** - Clean async handling
- **Unix sockets** - Docker and systemd integration
- **Lower maintenance** - No adapter complexity like Tesla
- **OTP native** - Leverages battle-tested `:httpc`

## Dependency Management

### Infrastructure Library Integration

**MANDATORY:** Infrastructure libraries are umbrella applications with shared build paths:

```elixir
# In apps/abyss/mix.exs, apps/ex_dns/mix.exs, apps/ex_dhcp/mix.exs
def project do
  [
    app: :abyss,  # or :ex_dns, :ex_dhcp
    build_path: "../../_build",
    config_path: "../../config/config.exs",
    deps_path: "../../deps",
    lockfile: "../../mix.lock"
  ]
end
```

### Cross-Application Dependencies

**MANDATORY PATTERNS:**
1. All protocol apps depend on infrastructure libs with `in_umbrella: true`
2. All apps use `yellow_dog_telemetry` for telemetry
3. Console app depends on all protocol apps
4. Core `yellow_dog` app orchestrates all services

**Example:**
```elixir
# In apps/yellow_dog_dns/mix.exs
defp deps do
  [
    {:ex_dns, in_umbrella: true},
    {:abyss, in_umbrella: true},
    {:yellow_dog_telemetry, in_umbrella: true}
  ]
end
```

## Configuration Management

### Centralized Configuration

**MANDATORY:** Use `YellowDog.Config` for all configuration:

```elixir
# Get configuration
YellowDog.get_config(:key)
YellowDog.Config.get(:dns, :port)
YellowDog.Config.service_enabled?(:dns)
```

### TOML Configuration Files

**MANDATORY:** Service configuration uses TOML format:

```toml
[core]
dns = true
mdns = true
dhcpv4 = true
dhcpv6 = true

[dns]
listen = "0.0.0.0"
port = 53

[dhcpv4]
listen = "0.0.0.0"
port = 67
```

### Test Environment

**MANDATORY:** Test environment auto-adjusts:
- DNS disabled (privileged port)
- DHCPv4 uses port 6767
- DHCPv6 uses port 5667
- IP strings converted to tuples

## Protocol Application Patterns

### Server Implementation

**MANDATORY STRUCTURE:**

1. **Server Module** - GenServer using Abyss
2. **Handler Module** - Implements `Abyss.Handler` behaviour
3. **Supervisor Module** - OTP supervisor with pre/post-start tasks
4. **Manager Modules** - Lease/service/zone management with ETS

**Example Structure:**
```
apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/
├── dhcpv4.ex           # Public API
├── server.ex           # Abyss-based UDP server
├── handler.ex          # Message handler
├── supervisor.ex       # Service supervisor
├── lease_manager.ex    # Lease tracking (ETS)
└── address_pool.ex     # Pool management
```

### Conditional Service Starting

**MANDATORY:** Services start based on configuration:

```elixir
defmodule YellowDog.<Protocol>.Supervisor do
  def start_link(opts) do
    if YellowDog.Config.service_enabled?(:<protocol>) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end
end
```

## Web Console Standards

### Phoenix LiveView Architecture

**MANDATORY:** Console follows Phoenix 1.8 patterns:

1. **Function Components** - Use `use YellowDog.Console, :html`
2. **LiveView Modules** - Use `use YellowDog.Console, :live_view`
3. **DaisyUI Components** - 12 reusable components in `CoreComponents`
4. **Layout System** - Single root template with function components

### Component Library

**AVAILABLE COMPONENTS:**
- `<.stat>` - Statistics display
- `<.badge>` - Status badges
- `<.card>` - Content cards
- `<.modal>` - Modal dialogs
- `<.table>` - Data tables with actions
- `<.progress>` - Progress bars
- `<.progress_radial>` - Radial progress
- `<.status_indicator>` - Service status
- `<.toast>` - Notifications
- `<.loading>` - Loading spinners

### Asset Building

**MANDATORY:** Use Bun for JavaScript:

```bash
# Build commands
bun run build       # Development with sourcemaps
bun run build:prod  # Production minified
bun run watch       # Watch mode

# Mix aliases
mix assets.setup    # Create Phoenix deps symlinks
mix assets.build    # Tailwind + Bun build
mix assets.deploy   # Production build
```

**MANDATORY:** Phoenix dependencies symlinked from `deps/` to `node_modules/`

## Code Quality Standards

### Compilation

**MANDATORY RULES:**
1. Code MUST compile with `--warnings-as-errors`
2. NO unused variables, functions, or module attributes
3. NO typing violations in pattern matching
4. Proper module aliasing (no unused aliases)

### Formatting

**MANDATORY:** Use `mix format` with project `.formatter.exs`:

```bash
mix format              # Format all code
mix format --check-formatted  # CI check
```

### Linting

**MANDATORY:** Credo linting enabled in CI:

```bash
mix credo --strict      # Run locally
```

**NEVER disable credo job in CI workflow.**

### Type Checking

**MANDATORY:** Dialyzer for static analysis:

```bash
mix dialyzer --halt-exit-status  # CI check
```

## CI/CD Standards

### GitHub Actions Workflow

**MANDATORY JOBS:**
1. **Compile** - `mix compile --warnings-as-errors`
2. **Format Check** - `mix format --check-formatted`
3. **Credo** - `mix credo --strict`
4. **Dialyzer** - `mix dialyzer --halt-exit-status`
5. **Test** - `mix test --exclude privileged_port`

**Matrix Testing:**
- Elixir 1.18
- OTP 27 and 28

**PROHIBITED:**
- ❌ Disabling any CI jobs
- ❌ Skipping warnings-as-errors
- ❌ Committing code that fails CI

### Docker Builds

**MANDATORY:** Multi-architecture support:
- x86_64
- aarch64
- Nix-based reproducible builds
- Push to GHCR and Docker Hub

## Telemetry Standards

### Event Emission

**MANDATORY:** All services emit telemetry events:

```elixir
:telemetry.execute(
  [:yellow_dog, :<protocol>, :<event>],
  %{count: 1},
  %{metadata: value}
)
```

### Centralized Telemetry

**MANDATORY:** Use `yellow_dog_telemetry` package:

```elixir
# All apps depend on
{:yellow_dog_telemetry, in_umbrella: true}
```

### Logging Standards

**MANDATORY RULE:** ALL logging MUST use `yellow_dog_telemetry` via telemetry events.

**Prohibited:**
- ❌ Direct `Logger.info/1` calls
- ❌ Direct `Logger.warn/1` calls
- ❌ Direct `Logger.error/1` calls
- ❌ Direct `Logger.debug/1` calls
- ❌ Direct `require Logger` for logging purposes
- ❌ Any direct Logger module usage for application logging

**Required Approach:**
1. Emit telemetry events for all loggable actions
2. Attach Logger handlers to telemetry events for log output
3. Centralize all logging configuration in `yellow_dog_telemetry`

**Implementation Pattern - Emitting Events:**

```elixir
# In your protocol/service module
defmodule YellowDog.Dns.Handler do
  # Instead of: Logger.info("DNS query received: #{inspect(query)}")
  # Use telemetry:
  def handle_query(query) do
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :received],
      %{count: 1},
      %{query: query, timestamp: System.system_time(:millisecond)}
    )

    # ... process query ...

    :telemetry.execute(
      [:yellow_dog, :dns, :query, :completed],
      %{duration_ms: duration},
      %{query: query, result: result}
    )
  end

  # For errors - instead of: Logger.error("DNS resolution failed: #{reason}")
  def handle_error(query, reason) do
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :error],
      %{count: 1},
      %{query: query, reason: reason, severity: :error}
    )
  end
end
```

**Implementation Pattern - Attaching Logger Handlers:**

```elixir
# In apps/yellow_dog_telemetry/lib/yellow_dog/telemetry.ex
defmodule YellowDog.Telemetry do
  require Logger

  @doc """
  Attach logger handlers to telemetry events.
  Call this during application startup.
  """
  def attach_logger_handlers do
    # DNS logging
    :telemetry.attach(
      "yellow-dog-dns-logger",
      [:yellow_dog, :dns, :query, :received],
      &__MODULE__.log_dns_query/4,
      %{level: :info}
    )

    :telemetry.attach(
      "yellow-dog-dns-error-logger",
      [:yellow_dog, :dns, :query, :error],
      &__MODULE__.log_dns_error/4,
      %{level: :error}
    )

    # DHCP logging
    :telemetry.attach(
      "yellow-dog-dhcp-logger",
      [:yellow_dog, :dhcpv4, :lease, :granted],
      &__MODULE__.log_dhcp_lease/4,
      %{level: :info}
    )

    # Add more handlers as needed...
    :ok
  end

  # Handler implementations
  def log_dns_query(_event, measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DNS query received: #{inspect(metadata.query)}"
    end)
  end

  def log_dns_error(_event, _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DNS error: #{inspect(metadata.reason)} for query #{inspect(metadata.query)}"
    end)
  end

  def log_dhcp_lease(_event, _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DHCP lease granted: #{metadata.ip} to #{metadata.mac}"
    end)
  end
end
```

**Application Startup Integration:**

```elixir
# In apps/yellow_dog/lib/yellow_dog/application.ex
defmodule YellowDog.Application do
  def start(_type, _args) do
    # Attach logger handlers before starting services
    YellowDog.Telemetry.attach_logger_handlers()

    children = [
      # ... supervisors ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**Rationale:**
- **Centralized observability** - All logging flows through telemetry
- **Structured logging** - Metadata is always available
- **Metrics integration** - Same events power both logs and metrics
- **Configurable verbosity** - Enable/disable log handlers without code changes
- **Testing friendly** - Attach test handlers to verify logging behavior
- **Consistent format** - All logs follow the same pattern
- **Performance** - Telemetry is lightweight; logging is opt-in via handlers

**Event Naming Convention:**

```elixir
# Pattern: [:yellow_dog, <service>, <resource>, <action>]
[:yellow_dog, :dns, :query, :received]
[:yellow_dog, :dns, :query, :completed]
[:yellow_dog, :dns, :query, :error]
[:yellow_dog, :dns, :cache, :hit]
[:yellow_dog, :dns, :cache, :miss]
[:yellow_dog, :dhcpv4, :lease, :requested]
[:yellow_dog, :dhcpv4, :lease, :granted]
[:yellow_dog, :dhcpv4, :lease, :expired]
[:yellow_dog, :dhcpv6, :lease, :requested]
[:yellow_dog, :mdns, :service, :registered]
[:yellow_dog, :mdns, :discovery, :query]
```

### Metrics Collection

**MANDATORY:** Web console displays real-time metrics:
- Service status and uptime
- Request counts and latency
- Error rates
- Resource utilization

## Testing Standards

### Test Organization

**MANDATORY STRUCTURE:**
- Unit tests in `test/<module>_test.exs`
- Integration tests tagged with `:integration`
- Slow tests tagged with `:slow`
- Privileged port tests tagged with `:privileged_port`

### Test Exclusions

**MANDATORY:** CI excludes privileged port tests:

```bash
mix test --exclude privileged_port
```

### Infrastructure Library Test Coverage

**MANDATORY:** Infrastructure libraries MUST achieve 100% unit test pass rate:

**Scope:** This requirement applies to:
- `apps/abyss` - UDP server library
- `apps/ex_dns` - DNS protocol library
- `apps/ex_dhcp` - DHCP protocol library

**Rationale:** These libraries are critical dependencies for multiple protocol applications. High reliability through comprehensive testing is non-negotiable. Any failing tests indicate bugs that could affect all dependent services.

**Enforcement:**
```bash
# All unit tests must pass (exit code 0)
cd apps/abyss && mix test
cd apps/ex_dns && mix test
cd apps/ex_dhcp && mix test
```

**CI Requirements:**
- Separate CI job per infrastructure library
- Exit on first test failure
- NO test exclusions or skips allowed
- Integration/slow tests are separate (not subject to 100% requirement)

**Coverage vs Pass Rate:**
- **Pass Rate (MANDATORY 100%)**: All existing unit tests must pass
- **Coverage (Target)**: Aim for high coverage but not mandatory 100%
- Core YellowDog apps have coverage targets (not mandatory 100%)

### Test Coverage Targets

**TARGET:** Maintain high test coverage for core applications:
- Protocol message parsing/encoding
- Lease/service management
- Zone resolution
- Error handling

## Documentation Standards

### Module Documentation

**MANDATORY:** All public modules have `@moduledoc`:

```elixir
defmodule YellowDog.<Module> do
  @moduledoc """
  Brief description of module purpose.

  Detailed explanation of functionality,
  usage patterns, and examples.
  """
end
```

### Function Documentation

**MANDATORY:** All public functions have `@doc`:

```elixir
@doc """
Brief description.

## Parameters
- `param1` - Description
- `param2` - Description

## Returns
- `{:ok, result}` on success
- `{:error, reason}` on failure

## Examples
    iex> function(arg)
    {:ok, result}
"""
@spec function(term()) :: {:ok, term()} | {:error, term()}
def function(param) do
  # Implementation
end
```

### CLAUDE.md

**MANDATORY:** Keep `CLAUDE.md` updated with:
- Architecture changes
- New features
- Configuration updates
- Development workflow changes

## Security Standards

### Input Validation

**MANDATORY:** All external input MUST be validated:
- DNS queries (malformed packets)
- DHCP requests (invalid options)
- mDNS announcements (malicious data)
- Web console input (XSS prevention)

### OWASP Compliance

**MANDATORY:** Prevent OWASP Top 10 vulnerabilities:
- Command injection
- XSS (Cross-Site Scripting)
- SQL injection (N/A, no SQL)
- Insecure deserialization
- Security misconfiguration

### Privilege Separation

**MANDATORY:** Services run with minimal privileges:
- Non-root user
- Capability-based permissions
- Sandboxed environments

## Performance Standards

### Memory Management

**MANDATORY:** Efficient resource usage:
- ETS tables for high-performance lookups
- Process pooling for concurrent requests
- Garbage collection tuning
- Memory limits per service

### Benchmarking

**MANDATORY:** Performance testing:

```bash
# DNS benchmarking
dnsperf -n 100000 -d queries.txt -s 127.0.0.1 -p 53
```

### Monitoring

**MANDATORY:** Track key metrics:
- Response time (p50, p95, p99)
- Throughput (queries/second)
- Memory usage
- Process count

## Version Control Standards

### Commit Messages

**MANDATORY:** Semantic release format:

```
type(scope): brief description

Detailed explanation of changes,
rationale, and impact.

Breaking changes noted with BREAKING CHANGE:
```

**Types:** feat, fix, docs, style, refactor, perf, test, chore, ci

### Branch Strategy

**MANDATORY:**
- `main` - Stable releases
- `develop` - Integration branch
- Feature branches for new work
- PR required for main/develop

### Pull Requests

**MANDATORY:** PRs must:
- Pass all CI checks
- Include tests for new features
- Update documentation
- Have descriptive title and body

## Release Standards

### Versioning

**MANDATORY:** Semantic versioning (MAJOR.MINOR.PATCH):
- MAJOR: Breaking changes
- MINOR: New features (backward compatible)
- PATCH: Bug fixes

### Release Process

**MANDATORY STEPS:**
1. Update version in `mix.exs`
2. Update `CHANGELOG.md`
3. Run full test suite
4. Build Docker images
5. Tag release in git
6. Publish to Hex (if applicable)
7. Deploy to production

### Changelog

**MANDATORY:** Keep `CHANGELOG.md` with:
- Added features
- Changed functionality
- Deprecated features
- Removed functionality
- Fixed bugs
- Security patches

## Development Environment

### devenv Setup

**MANDATORY:** Use devenv for consistency:

```bash
direnv allow        # Activate environment
# or
devenv shell        # Manual activation
```

**Included Tools:**
- Elixir 1.18 with OTP 27
- Git, watchman, inotify-tools
- JavaScript: pnpm, bun
- Tailwind CSS 4

### Editor Configuration

**RECOMMENDED:**
- ElixirLS for LSP
- Mix format on save
- Credo integration
- Dialyzer integration

## Prohibited Practices

### ❌ NEVER DO:

1. **Disable CI jobs** - All jobs must remain active
2. **Use direct socket libraries** - Use Abyss for UDP, :thousand_island for TCP, :http_fetch for HTTP
3. **Skip warnings** - Code must compile with `--warnings-as-errors`
4. **Commit without tests** - New features require tests
5. **Hardcode configuration** - Use YellowDog.Config
6. **Mix protocol implementations** - Keep DNS/DHCP/mDNS separate
7. **Bypass validation** - All external input must be validated
8. **Create circular dependencies** - Maintain clean dependency tree
9. **Use deprecated functions** - Keep code up to date
10. **Ignore telemetry** - All services must emit events
11. **Commit failing infrastructure library tests** - 100% pass rate required for abyss, ex_dns, ex_dhcp
12. **Use alternative HTTP clients** - Only :http_fetch is permitted for HTTP requests
13. **Use direct Logger calls** - All logging MUST use yellow_dog_telemetry via telemetry events

## Migration History

### Recent Major Changes

**Infrastructure Library Integration (2025):**
- Moved `abyss`, `ex_dns`, `ex_dhcp` from external deps to umbrella apps
- Updated dependency names (`dhcp_ex` → `ex_dhcp`)
- Configured shared build paths
- Unified build and test workflows

**Module Naming Refactor (2025):**
- Migrated from flat naming to dot-notation
- All modules now follow `YellowDog.<AppName>` pattern
- Directory structure reflects module hierarchy

## Constitutional Amendments

This constitution is a living document. Changes require:

1. **Proposal** - Submit PR with constitutional changes
2. **Review** - Team review and discussion
3. **Approval** - Consensus from maintainers
4. **Documentation** - Update CLAUDE.md accordingly

**Amendment History:**
- **v1.3.0 (2025-12-22)**: Added mandatory Logging Standards requiring all logging via yellow_dog_telemetry with telemetry-attached handlers
- **v1.2.0 (2025-11-10)**: Added mandatory HTTP transport standard requiring :http_fetch for all HTTP requests
- **v1.1.0 (2025-11-10)**: Added mandatory 100% unit test pass rate for infrastructure libraries (abyss, ex_dns, ex_dhcp)
- **v1.0.0 (2025-11-07)**: Initial constitution ratified

---

**Ratification Date:** 2025-11-07
**Last Amended:** 2025-12-22
**Version:** 1.3.0
**Maintainers:** Yellow Dog DNS Team
