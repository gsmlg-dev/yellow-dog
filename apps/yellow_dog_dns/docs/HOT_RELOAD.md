# DNS Hot-Reload System

This guide explains the hot-reload system for DNS views configuration in YellowDog DNS server, which enables zero-downtime configuration updates without requiring server restarts.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Components](#components)
- [Configuration](#configuration)
- [Usage](#usage)
- [Examples](#examples)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Overview

The hot-reload system allows you to update DNS view configuration (split-horizon DNS, ACLs, zone assignments) while the DNS server is running. Changes are detected automatically, validated, and applied atomically without dropping connections or causing downtime.

### Key Features

- **Zero Downtime**: Configuration updates without server restart
- **Automatic Detection**: File system watching with change notifications
- **Debouncing**: Prevents reload storms during rapid file changes
- **Atomic Updates**: All-or-nothing configuration swaps
- **Validation**: Configuration checked before applying
- **Rollback**: Failed updates don't affect running configuration
- **Telemetry**: Comprehensive monitoring and statistics

## Architecture

The hot-reload system consists of three main components working together:

```
┌─────────────────┐
│  views.toml     │  ← Configuration File
└────────┬────────┘
         │ file change detected
         ▼
┌─────────────────┐
│ ConfigWatcher   │  ← File System Monitor
│  - inotify/     │     (debounce: 300ms)
│    fsevents     │
└────────┬────────┘
         │ calls reload_callback
         ▼
┌─────────────────┐
│ View.Manager    │  ← Atomic State Manager
│  - validate     │
│  - update       │
└────────┬────────┘
         │ provides current views
         ▼
┌─────────────────┐
│ Handler.UDP     │  ← DNS Query Handler
│  - query views  │
│  - match client │
└─────────────────┘
```

### Data Flow

1. **File Change**: User modifies `views.toml`
2. **Detection**: ConfigWatcher receives file system event
3. **Debouncing**: Timer waits for changes to settle (300ms default)
4. **Load**: ConfigWatcher parses TOML file
5. **Validate**: View.Manager validates new configuration
6. **Update**: If valid, Manager atomically swaps views
7. **Query**: Handler.UDP gets current views from Manager
8. **Match**: Client IP matched to appropriate view

## Components

### 1. ConfigWatcher

**Purpose**: Monitors configuration file for changes and triggers reloads.

**Location**: `YellowDog.Dns.View.ConfigWatcher`

**Features**:
- File system watching using `FileSystem` library (inotify on Linux, fsevents on macOS)
- Configurable debounce delay (default: 300ms)
- Manual reload trigger via `ConfigWatcher.reload/1`
- Statistics tracking (reload count, error count)
- Telemetry events for monitoring

**Key Functions**:
```elixir
# Start watcher
ConfigWatcher.start_link(
  config_path: "config/views.toml",
  reload_callback: fn views -> ViewManager.update_views(views) end,
  debounce_ms: 300
)

# Manual reload
ConfigWatcher.reload(watcher_pid)

# Get status
ConfigWatcher.status(watcher_pid)
# => %{
#   config_path: "config/views.toml",
#   watching: true,
#   last_reload: ~U[2025-01-15 10:30:45Z],
#   reload_count: 5,
#   error_count: 0
# }
```

### 2. View.Manager

**Purpose**: Manages current view configuration with atomic updates.

**Location**: `YellowDog.Dns.View.Manager`

**Features**:
- Thread-safe concurrent access
- Atomic view list updates
- Pre-update validation
- Duplicate name detection
- Change tracking (added/removed/modified views)
- Statistics API

**Key Functions**:
```elixir
# Start manager
ViewManager.start_link(views: initial_views)

# Get current views
views = ViewManager.get_views()

# Update views (atomic)
:ok = ViewManager.update_views(new_views)

# Get statistics
ViewManager.stats()
# => %{
#   view_count: 3,
#   update_count: 5,
#   last_update: ~U[2025-01-15 10:30:45Z],
#   view_names: ["internal", "dmz", "external"]
# }

# Match client to view
{:ok, view} = ViewManager.match_client({192, 168, 1, 100})
```

### 3. Handler.UDP

**Purpose**: DNS query handler that uses views from Manager.

**Location**: `YellowDog.Dns.Handler.UDP`

**Integration**:
- Starts View.Manager in `init/1`
- Optionally starts ConfigWatcher if hot-reload enabled
- Queries Manager for current views on each DNS request
- Matches client IP to appropriate view

## Configuration

### Application Configuration

Add to `config/config.exs` or environment-specific config:

```elixir
config :yellow_dog_dns,
  # Path to views TOML configuration file
  views_config_path: "config/views.toml",

  # Enable/disable hot-reload (default: false)
  hot_reload_enabled: true,

  # Debounce delay in milliseconds (default: 300)
  reload_debounce_ms: 300
```

### Views Configuration File

Create `config/views.toml`:

```toml
# Internal network view - full access
[[view]]
name = "internal"
match_clients = "localnets"
zones = ["corp.example.com", "internal.net", "dev.local"]
recursion_enabled = true

# DMZ view - restricted zones
[[view]]
name = "dmz"
match_clients = "10.0.0.0/8"
zones = ["dmz.example.com"]
recursion_enabled = false

# External view - public zones only
[[view]]
name = "external"
match_clients = "any"
zones = ["example.com", "www.example.com"]
recursion_enabled = false
```

## Usage

### Enabling Hot-Reload

1. **Create views configuration**:
   ```bash
   mkdir -p config
   cat > config/views.toml <<EOF
   [[view]]
   name = "default"
   match_clients = "any"
   zones = []
   recursion_enabled = true
   EOF
   ```

2. **Enable in configuration**:
   ```elixir
   # config/config.exs
   config :yellow_dog_dns,
     views_config_path: "config/views.toml",
     hot_reload_enabled: true
   ```

3. **Start DNS server**:
   ```bash
   mix run --no-halt
   # or
   iex -S mix
   ```

4. **Verify hot-reload is active**:
   ```elixir
   # In IEx
   YellowDog.Dns.status()
   ```

### Updating Configuration

Simply edit `config/views.toml` and save:

```bash
vim config/views.toml
# Make changes and save
```

ConfigWatcher automatically detects the change, validates, and applies it within ~300ms.

### Manual Reload

You can also trigger reloads manually:

```elixir
# In IEx or via API
alias YellowDog.Dns.View.ConfigWatcher
ConfigWatcher.reload()
```

## Examples

### Example 1: Basic Split-Horizon DNS

**Scenario**: Internal users see internal zones, external users see public zones.

```toml
# config/views.toml

[[view]]
name = "internal"
match_clients = "localnets"
zones = ["internal.company.com", "corp.company.com"]
recursion_enabled = true

[[view]]
name = "external"
match_clients = "any"
zones = ["www.company.com", "company.com"]
recursion_enabled = false
```

**Client Matching**:
- Client `192.168.1.100` → "internal" view → can query internal.company.com
- Client `8.8.8.8` → "external" view → can only query www.company.com

### Example 2: Three-Tier Network

**Scenario**: Corporate, DMZ, and public networks with different access.

```toml
[[view]]
name = "corporate"
match_clients = "10.0.0.0/8"
zones = ["corp.example.com", "internal.example.com"]
recursion_enabled = true

[[view]]
name = "dmz"
match_clients = "172.16.0.0/12"
zones = ["dmz.example.com", "api.example.com"]
recursion_enabled = false

[[view]]
name = "public"
match_clients = "any"
zones = ["example.com", "www.example.com"]
recursion_enabled = false
```

### Example 3: Office-Specific Views

**Scenario**: Different offices see different internal resources.

```toml
[[view]]
name = "newyork_office"
match_clients = "192.168.1.0/24"
zones = ["ny.corp.example.com", "corp.example.com"]
recursion_enabled = true

[[view]]
name = "london_office"
match_clients = "192.168.2.0/24"
zones = ["london.corp.example.com", "corp.example.com"]
recursion_enabled = true

[[view]]
name = "default"
match_clients = "any"
zones = ["example.com"]
recursion_enabled = false
```

### Example 4: Adding a New View Without Downtime

**Initial configuration**:
```toml
[[view]]
name = "internal"
match_clients = "localnets"
zones = ["corp.example.com"]
recursion_enabled = true

[[view]]
name = "external"
match_clients = "any"
zones = ["example.com"]
recursion_enabled = false
```

**Add new view**:
```toml
[[view]]
name = "internal"
match_clients = "localnets"
zones = ["corp.example.com"]
recursion_enabled = true

# NEW: Guest network with restricted access
[[view]]
name = "guest"
match_clients = "10.99.0.0/16"
zones = ["guest.example.com"]
recursion_enabled = true

[[view]]
name = "external"
match_clients = "any"
zones = ["example.com"]
recursion_enabled = false
```

Save the file → ConfigWatcher detects change → Views updated automatically → No downtime!

## Monitoring

### Telemetry Events

The hot-reload system emits telemetry events for monitoring:

#### ConfigWatcher Events

```elixir
# Reload started
[:yellow_dog, :dns, :view, :config_reload, :start]
# Metadata: %{config_path: path}

# Reload succeeded
[:yellow_dog, :dns, :view, :config_reload, :success]
# Measurements: %{duration_ms: duration}
# Metadata: %{config_path: path, view_count: count, view_names: names}

# Reload failed
[:yellow_dog, :dns, :view, :config_reload, :error]
# Measurements: %{duration_ms: duration}
# Metadata: %{config_path: path, reason: reason}
```

#### ViewManager Events

```elixir
# Views updated
[:yellow_dog, :dns, :view, :manager, :update]
# Measurements: %{view_count: count}
# Metadata: %{view_names: names, update_count: count}
```

### Logging

Hot-reload operations are logged with telemetry:

```
[info] ConfigWatcher started config_path=config/views.toml
[info] Views reloaded successfully duration_ms=15 view_count=3
[error] Failed to load view configuration reason={:toml_parse_error, ...}
[error] View validation failed reason={:duplicate_view_names, ["internal"]}
```

### Status APIs

Check system status programmatically:

```elixir
# ConfigWatcher status
ConfigWatcher.status()
# => %{
#   config_path: "config/views.toml",
#   watching: true,
#   last_reload: ~U[2025-01-15 10:30:45Z],
#   reload_count: 12,
#   error_count: 1
# }

# ViewManager statistics
ViewManager.stats()
# => %{
#   view_count: 3,
#   update_count: 12,
#   last_update: ~U[2025-01-15 10:30:45Z],
#   view_names: ["internal", "dmz", "external"]
# }
```

## Troubleshooting

### Hot-Reload Not Working

**Problem**: Changes to `views.toml` not detected.

**Checks**:
1. Verify hot-reload is enabled:
   ```elixir
   Application.get_env(:yellow_dog_dns, :hot_reload_enabled)
   # Should return: true
   ```

2. Check config path is set:
   ```elixir
   Application.get_env(:yellow_dog_dns, :views_config_path)
   # Should return path to views.toml
   ```

3. Verify file exists:
   ```bash
   ls -la config/views.toml
   ```

4. Check ConfigWatcher status:
   ```elixir
   ConfigWatcher.status()
   # watching should be true
   ```

### Configuration Validation Errors

**Problem**: New configuration rejected with validation error.

**Common Errors**:

1. **Duplicate view names**:
   ```
   {:error, {:duplicate_view_names, ["internal"]}}
   ```
   **Solution**: Ensure all view names are unique.

2. **Invalid TOML syntax**:
   ```
   {:error, {:toml_parse_error, ...}}
   ```
   **Solution**: Check TOML syntax, ensure proper escaping and formatting.

3. **Invalid ACL pattern**:
   ```
   {:error, {:invalid_acl, "invalid_pattern"}}
   ```
   **Solution**: Use valid ACL patterns (see View.ACL documentation).

### File Watching Not Working

**Problem**: File changes not detected by ConfigWatcher.

**Possible Causes**:
1. **inotify limits (Linux)**: Increase limits if needed:
   ```bash
   # Check current limit
   cat /proc/sys/fs/inotify/max_user_watches

   # Increase limit
   echo 524288 | sudo tee /proc/sys/fs/inotify/max_user_watches
   ```

2. **Network filesystem**: File watching may not work on NFS/CIFS. Use manual reload:
   ```elixir
   ConfigWatcher.reload()
   ```

3. **Docker/VM issues**: File events may not propagate properly. Use polling or manual reload.

### Rollback After Failed Update

**Problem**: Invalid configuration caused error, need to revert.

**Solution**: Old configuration is automatically preserved. Edit the file to fix errors:

```bash
# Fix the error in views.toml
vim config/views.toml

# Save - ConfigWatcher will retry automatically
# Or trigger manual reload:
# ConfigWatcher.reload()
```

Check logs to see why validation failed:
```elixir
ConfigWatcher.status()
# Look at error_count and check logs for error details
```

## Best Practices

### 1. Test Changes Before Applying

Test configuration syntax before saving to production:

```bash
# Validate TOML syntax
cat config/views.toml | tomll > /dev/null && echo "Valid TOML"

# Or use elixir
iex> {:ok, toml} = File.read("config/views.toml")
iex> {:ok, config} = Toml.decode(toml)
iex> YellowDog.Dns.View.Config.from_toml(config)
```

### 2. Use Version Control

Keep views configuration in version control:

```bash
git add config/views.toml
git commit -m "Add guest network view"
git push
```

This provides:
- Change history
- Easy rollback
- Code review for configuration changes
- Audit trail

### 3. Monitor Reload Success

Set up alerts for failed reloads:

```elixir
# Attach telemetry handler
:telemetry.attach(
  "dns-reload-monitor",
  [:yellow_dog, :dns, :view, :config_reload, :error],
  fn _event, _measurements, metadata, _config ->
    # Send alert (email, Slack, PagerDuty, etc.)
    Logger.error("DNS view reload failed: #{inspect(metadata)}")
  end,
  nil
)
```

### 4. Use Gradual Rollouts

For large changes, update views gradually:

```toml
# Step 1: Add new view (doesn't affect existing)
[[view]]
name = "new_view"
match_clients = "10.50.0.0/24"
zones = ["new.example.com"]
recursion_enabled = true

# Existing views remain unchanged
[[view]]
name = "internal"
# ...
```

Test the new view, then proceed with broader changes.

### 5. Document View Purposes

Add comments to views.toml:

```toml
# Corporate network - full internal access
# Used by: Employees, contractors
# Updated: 2025-01-15
[[view]]
name = "corporate"
match_clients = "10.0.0.0/8"
zones = ["corp.example.com"]
recursion_enabled = true
```

### 6. Set Appropriate Debounce

Adjust debounce timing based on your workflow:

```elixir
# Faster response (good for development)
config :yellow_dog_dns,
  reload_debounce_ms: 100

# Slower (good for production with frequent edits)
config :yellow_dog_dns,
  reload_debounce_ms: 1000
```

### 7. Regular Configuration Audits

Periodically review view configuration:

```elixir
# Get all views
views = ViewManager.get_views()

# Check for unused views
# Review ACL patterns
# Verify zone assignments
```

## Performance Impact

### Memory

- **View.Manager**: Minimal overhead (~few KB per view)
- **ConfigWatcher**: ~1-2 MB for file watching infrastructure

### CPU

- **File watching**: Negligible (event-driven)
- **Configuration reload**: <10ms for typical configs (<100 views)
- **View matching**: No impact (views cached in Manager)

### Latency

- **DNS queries**: No added latency
  - Views fetched once per query from Manager
  - GenServer call is ~1-5 microseconds
  - View matching is in-memory operation

## Security Considerations

### 1. File Permissions

Protect views configuration file:

```bash
chmod 640 config/views.toml
chown dns:dns config/views.toml
```

### 2. Validation

ConfigWatcher validates all configuration before applying. Invalid configs are rejected, preventing:
- Syntax errors from breaking DNS
- Malformed views from causing crashes
- Duplicate names from creating conflicts

### 3. Audit Trail

Use file system auditing to track configuration changes:

```bash
# Linux with auditd
auditctl -w /path/to/views.toml -p wa -k dns_config_changes

# View audit log
ausearch -k dns_config_changes
```

### 4. Access Control

Restrict who can modify views configuration:
- Use proper file permissions
- Require code review for changes
- Log all configuration updates
- Alert on unauthorized changes

## Related Documentation

- [DNS Views Configuration](./DNS_VIEWS.md)
- [View ACLs](./VIEW_ACLS.md)
- [Zone Management](./ZONES.md)
- [Telemetry Guide](./TELEMETRY.md)

## Support

For issues or questions:
- Check logs: `tail -f log/yellow_dog.log`
- Review status: `YellowDog.Dns.status()`
- File issues: GitHub repository
- Documentation: `apps/yellow_dog_dns/docs/`
