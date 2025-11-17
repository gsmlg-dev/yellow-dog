# Quickstart Guide: Console Settings Management

**Feature**: Console Settings Management (001-console-settings)
**Date**: 2025-11-10
**Phase**: Phase 1 - Design Artifacts
**Plan**: [plan.md](./plan.md)

## Overview

This guide helps developers get started with the Console Settings Management feature. It covers local development setup, testing workflows, and common development tasks.

---

## Prerequisites

- Elixir 1.18 with OTP 27 or 28
- Phoenix 1.8.1 and Phoenix LiveView 1.1.17
- Bun (for asset building)
- Yellow Dog development environment (direnv or devenv shell)

---

## Local Development Setup

### 1. Activate Development Environment

```bash
# Navigate to project root
cd /path/to/yellow-dog

# Activate development environment
direnv allow
# OR
devenv shell
```

### 2. Install Dependencies

```bash
# Get Elixir dependencies
mix deps.get

# Setup web console assets
cd apps/yellow_dog_console
mix assets.setup
cd ../..
```

### 3. Start the Application

```bash
# Start Phoenix server with IEx
cd apps/yellow_dog_console
iex -S mix phx.server
```

Navigate to: **http://localhost:4000/settings**

### 4. Watch Mode for Development

In a separate terminal:

```bash
cd apps/yellow_dog_console

# Watch JavaScript changes
bun run watch

# Watch Tailwind CSS changes
mix tailwind default --watch
```

---

## Quick Feature Tour

### Access Settings Page

1. Navigate to `http://localhost:4000/settings`
2. You'll see 4 tabs: **DNS**, **mDNS**, **DHCPv4**, **DHCPv6**
3. Click any tab to view service configuration

### Edit Configuration

1. Select a service tab (e.g., **DNS**)
2. Modify field values (e.g., change port from `53` to `5353`)
3. Observe real-time validation feedback
4. Click **Save** button
5. Notice "Pending" badge appears on tab

### Apply Changes

1. After saving configuration, click **Apply Changes** button
2. Service will restart with new configuration
3. "Pending" badge disappears
4. Success toast displays: "DNS configuration applied successfully"

### Manage DHCP Pools

1. Select **DHCPv4** or **DHCPv6** tab
2. Click **Add Pool** button
3. Fill in pool details:
   - Name: "Office Network"
   - Range Start: "192.168.1.100"
   - Range End: "192.168.1.200"
   - Lease Time: "3600" (seconds)
   - Gateway: "192.168.1.1"
   - DNS Servers: ["8.8.8.8", "8.8.4.4"]
4. Click **Save Pool**
5. Click **Save** to persist to configuration file
6. Click **Apply Changes** to restart service

---

## Testing Workflows

### Run All Tests

```bash
# From project root
mix test apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs

# Or run all console tests
mix test apps/yellow_dog_console
```

### Run Specific Test Suite

```bash
# LiveView integration tests
mix test apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs

# Config manager tests
mix test apps/yellow_dog_console/test/yellow_dog/console/config_manager_test.exs

# Validation tests
mix test apps/yellow_dog_console/test/yellow_dog/console/validators_test.exs
```

### Run Tests with Coverage

```bash
mix test --cover
```

### Run Tests in Watch Mode

```bash
mix test.watch apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs
```

---

## Common Development Tasks

### Format Code

```bash
# Format all code
mix format

# Check formatting without modifying
mix format --check-formatted
```

### Run Linting

```bash
# Run Credo
mix credo

# Run Credo in strict mode
mix credo --strict

# Run Dialyzer
mix dialyzer
```

### Compile with Warnings as Errors

```bash
mix compile --warnings-as-errors
```

### Build Assets

```bash
cd apps/yellow_dog_console

# Development build (with sourcemaps)
bun run build

# Production build (minified)
bun run build:prod

# Tailwind CSS
mix tailwind default

# All assets (Tailwind + Bun)
mix assets.build
```

---

## Testing Specific Scenarios

### Test Configuration Validation

```elixir
# In IEx session
iex> alias YellowDog.Console.Settings.ServiceConfiguration
iex> alias YellowDog.Console.Validators

# Test port validation
iex> changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, %{port: 99999})
iex> changeset.errors
[port: {"must be less than or equal to %{count}", [count: 65535, validation: :number]}]

# Test IP address validation
iex> Validators.validate_ip("256.1.1.1", :ipv4)
{:error, "Invalid IP address format"}

iex> Validators.validate_ip("192.168.1.1", :ipv4)
:ok
```

### Test TOML File Preservation

```elixir
# In IEx session
iex> alias YellowDog.Console.ConfigManager

# Load configuration
iex> {:ok, config} = ConfigManager.load_config("/path/to/config.toml")

# Make updates
iex> updates = %{"dns.port" => 5353, "dns.listen" => "127.0.0.1"}
iex> ConfigManager.save_config("/path/to/config.toml", updates, backup: true)
:ok

# Verify comments preserved
iex> File.read!("/path/to/config.toml")
# Should show comments intact
```

### Test Optimistic Locking

```elixir
# In IEx session (Terminal 1)
iex> alias YellowDog.Console.Settings.ConfigurationVersion
iex> ConfigurationVersion.start_link([])
iex> version_info = ConfigurationVersion.get_version("/path/to/config.toml")
%{version: 0, timestamp: 1699627800}

# In another IEx session (Terminal 2)
iex> ConfigurationVersion.compare_and_swap("/path/to/config.toml", 0, 1699627800)
:ok  # Version incremented to 1

# Back in Terminal 1 (stale version)
iex> ConfigurationVersion.compare_and_swap("/path/to/config.toml", 0, 1699627800)
{:error, :version_mismatch}
```

### Test Service Restart

```elixir
# In IEx session
iex> alias YellowDog.Console.ServiceManager

# Get current DNS supervisor PID
iex> dns_pid = Process.whereis(YellowDog.Dns.Supervisor)
#PID<0.450.0>

# Apply new configuration and restart
iex> new_config = %{enabled: true, listen: "0.0.0.0", port: 5353}
iex> ServiceManager.apply_and_restart(:dns, new_config)
:ok

# Verify new PID
iex> new_dns_pid = Process.whereis(YellowDog.Dns.Supervisor)
#PID<0.512.0>  # Different PID = successful restart
```

---

## Manual Testing Scenarios

### Scenario 1: Concurrent Administrator Conflict

**Setup**: Open two browser windows at `http://localhost:4000/settings`

**Steps**:
1. **Browser A**: Load page at 14:30:00
2. **Browser B**: Load page at 14:30:05
3. **Browser A**: Modify DNS port to 5353, click Save → SUCCESS
4. **Browser B**: Modify DNS port to 5454, click Save → ERROR (version mismatch)
5. **Browser B**: Click "Reload and Discard Changes"
6. **Browser B**: See DNS port is 5353 (from Browser A's change)

**Expected Result**: Browser B's save is rejected with conflict modal

---

### Scenario 2: External File Modification

**Setup**: Settings page loaded in browser

**Steps**:
1. Load settings page in browser
2. Edit `/path/to/config.toml` directly in text editor
3. Change `dns.port = 53` to `dns.port = 5353`
4. Save file in editor
5. Return to browser, modify mDNS configuration
6. Click Save → ERROR (file modified)

**Expected Result**: Save rejected due to file timestamp change

---

### Scenario 3: Configuration Recovery

**Setup**: Delete or corrupt configuration file

**Steps**:
1. Stop Yellow Dog application
2. Rename or delete `config.toml`
3. Start application and navigate to `/settings`
4. Recovery modal appears with 3 options:
   - "Use Default Configuration"
   - "Restore from Backup" (if backups exist)
   - "Create New Configuration"
5. Select "Use Default Configuration"
6. Configuration loads with default values
7. Edit and save successfully

**Expected Result**: Recovery modal enables configuration restoration

---

### Scenario 4: Pool Overlap Detection

**Setup**: DHCPv4 settings with one existing pool

**Steps**:
1. Navigate to DHCPv4 tab
2. Existing pool: 192.168.1.100 - 192.168.1.200
3. Click "Add Pool"
4. Enter:
   - Range Start: 192.168.1.150
   - Range End: 192.168.1.250
5. Click "Save Pool" → ERROR

**Expected Result**: Validation error: "Pool overlaps with existing pool 'Office Network'"

---

## Troubleshooting

### Assets Not Building

```bash
# Clear node_modules and reinstall
cd apps/yellow_dog_console
rm -rf node_modules
mix assets.setup

# Rebuild assets
bun run build
```

### LiveView Not Updating

```bash
# Check Phoenix endpoint is running
iex> Phoenix.Endpoint.server?()
true

# Verify WebSocket connection in browser console
# Should see: "[phoenix] connected to ws://localhost:4000/live/websocket"
```

### Configuration File Not Found

```bash
# Check configuration path
iex> YellowDog.Config.config_path()
"/path/to/yellow-dog/config.toml"

# Verify file exists
ls -la /path/to/yellow-dog/config.toml

# Create default configuration if missing
iex> YellowDog.Console.ConfigManager.create_default_config("/path/to/config.toml")
:ok
```

### Service Restart Fails

```elixir
# Check supervisor status
iex> Supervisor.which_children(YellowDog.Application)
[
  {YellowDog.Dns.Supervisor, #PID<0.450.0>, :supervisor, [YellowDog.Dns.Supervisor]},
  ...
]

# Check if service is enabled in configuration
iex> YellowDog.Config.service_enabled?(:dns)
true

# Manual restart
iex> Supervisor.restart_child(YellowDog.Application, YellowDog.Dns.Supervisor)
{:ok, #PID<0.512.0>}
```

---

## Development Tips

### Use IEx for Interactive Testing

```elixir
# Start IEx with Phoenix
iex -S mix phx.server

# Recompile modules without restarting
iex> recompile()

# Test individual functions
iex> alias YellowDog.Console.Settings.ServiceConfiguration
iex> changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, %{port: 5353})
iex> changeset.valid?
true
```

### Use LiveView Debugging

```elixir
# In your LiveView module
def handle_event(event, params, socket) do
  require Logger
  Logger.debug("Event: #{event}, Params: #{inspect(params)}")
  # ... rest of handler
end
```

### Enable Verbose Logging

```elixir
# config/dev.exs
config :logger, level: :debug

# config/test.exs
config :logger, level: :warning  # Reduce test noise
```

### Use Phoenix LiveDashboard

Navigate to: **http://localhost:4000/dev/dashboard**

- Monitor LiveView processes
- View Ecto queries (if using database)
- Inspect telemetry metrics
- Debug memory usage

---

## Next Steps

After completing this quickstart:

1. Read [data-model.md](./data-model.md) for entity schemas
2. Review [contracts/settings-api.md](./contracts/settings-api.md) for LiveView events
3. Check [research.md](./research.md) for implementation patterns
4. Proceed to implementation tasks in `tasks.md` (generated via `/speckit.tasks`)

---

## Resources

- [Phoenix LiveView Documentation](https://hexdocs.pm/phoenix_live_view/)
- [DaisyUI Components](https://daisyui.com/components/)
- [Ecto Changeset Guide](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Yellow Dog CLAUDE.md](../../CLAUDE.md) - Project-specific patterns

---

**Questions or Issues?**

- Check troubleshooting section above
- Review error messages in browser console and server logs
- Inspect LiveView assigns using Phoenix LiveDashboard
- Validate TOML syntax using `Toml.decode_file/1` in IEx
