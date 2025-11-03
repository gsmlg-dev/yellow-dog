# DNS Operations API

This guide explains the Operations API for runtime control and management of the DNS views system in YellowDog DNS server. The Operations API provides programmatic access to view management, health monitoring, and system diagnostics.

## Table of Contents

- [Overview](#overview)
- [API Reference](#api-reference)
  - [View Management](#view-management)
  - [Status and Health](#status-and-health)
  - [Metrics](#metrics)
  - [Hot-Reload Control](#hot-reload-control)
  - [Diagnostics](#diagnostics)
- [Usage Examples](#usage-examples)
- [Integration](#integration)
- [Error Handling](#error-handling)
- [Best Practices](#best-practices)

## Overview

The `YellowDog.Dns.View.Operations` module provides a high-level API for managing and monitoring the DNS views system at runtime. It enables:

- **Dynamic View Management**: Add, remove, update views without downtime
- **Health Monitoring**: Check system health and component status
- **Metrics Collection**: Gather statistics for monitoring dashboards
- **Runtime Control**: Trigger reloads and control hot-reload behavior
- **Diagnostics**: Test configurations and troubleshoot issues

### Key Features

- **Safe Operations**: All operations include validation and error handling
- **Atomic Updates**: View changes are applied atomically
- **Non-Disruptive**: Operations don't affect ongoing DNS queries
- **Comprehensive**: Full coverage of system management needs
- **Observable**: All operations emit telemetry events

## API Reference

### View Management

#### add_view/2

Add a new view to the system.

**Signature:**
```elixir
@spec add_view(View.t(), keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `view` - The View struct to add
- `opts` - Options:
  - `:manager_pid` - ViewManager PID (default: `ViewManager`)

**Returns:**
- `{:ok, %{added: [name], total_views: count}}` on success
- `{:error, reason}` on failure

**Example:**
```elixir
alias YellowDog.Dns.View
alias YellowDog.Dns.View.Operations

# Create new view
guest_view = View.new("guests", "10.99.0.0/16", ["guest.example.com"], true)

# Add to system
{:ok, result} = Operations.add_view(guest_view)
# => {:ok, %{added: ["guests"], total_views: 4}}
```

**Errors:**
- `{:duplicate_view_name, name}` - View with this name already exists
- `{:manager_error, reason}` - ViewManager is unavailable

---

#### remove_view/2

Remove a view from the system by name.

**Signature:**
```elixir
@spec remove_view(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `view_name` - Name of the view to remove
- `opts` - Options (`:manager_pid`)

**Returns:**
- `{:ok, %{removed: [name], total_views: count}}` on success
- `{:error, reason}` on failure

**Example:**
```elixir
{:ok, result} = Operations.remove_view("old_view")
# => {:ok, %{removed: ["old_view"], total_views: 3}}
```

**Errors:**
- `:view_not_found` - No view with this name exists
- `:cannot_remove_last_view` - Cannot remove the only view
- `{:manager_error, reason}` - ViewManager is unavailable

---

#### update_view/3

Update an existing view with new configuration.

**Signature:**
```elixir
@spec update_view(String.t(), View.t(), keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `view_name` - Name of view to update
- `updated_view` - New View struct (must have same name)
- `opts` - Options (`:manager_pid`)

**Returns:**
- `{:ok, %{updated: [name], total_views: count}}` on success
- `{:error, reason}` on failure

**Example:**
```elixir
# Get current view and modify it
{:ok, current} = Operations.get_view_info("internal")
updated = View.new("internal", "localnets", ["corp.example.com", "new.example.com"], true)

{:ok, result} = Operations.update_view("internal", updated)
# => {:ok, %{updated: ["internal"], total_views: 3}}
```

**Errors:**
- `:view_not_found` - View doesn't exist
- `{:name_mismatch, expected, actual}` - View name doesn't match
- `{:manager_error, reason}` - ViewManager is unavailable

---

#### replace_all_views/2

Replace all views with a new set atomically.

**Signature:**
```elixir
@spec replace_all_views([View.t()], keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `new_views` - List of new View structs
- `opts` - Options (`:manager_pid`)

**Returns:**
- `{:ok, %{total_views: count, previous_count: count}}` on success
- `{:error, reason}` on failure

**Example:**
```elixir
new_views = [
  View.new("internal", "localnets", ["corp.example.com"], true),
  View.new("external", "any", ["public.example.com"], false)
]

{:ok, result} = Operations.replace_all_views(new_views)
# => {:ok, %{total_views: 2, previous_count: 3}}
```

**Errors:**
- `{:duplicate_view_names, names}` - Duplicate names in new views
- `{:invalid_view_type}` - List contains non-View structs
- `{:manager_error, reason}` - ViewManager is unavailable

---

### Status and Health

#### status/1

Get comprehensive system status including all components.

**Signature:**
```elixir
@spec status(keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `opts` - Options:
  - `:manager_pid` - ViewManager PID
  - `:watcher_pid` - ConfigWatcher PID (optional)

**Returns:**
```elixir
{:ok, %{
  manager: %{
    view_count: 3,
    update_count: 5,
    last_update: ~U[2025-01-15 10:30:45Z],
    view_names: ["internal", "dmz", "external"]
  },
  watcher: %{
    config_path: "config/views.toml",
    watching: true,
    last_reload: ~U[2025-01-15 10:30:45Z],
    reload_count: 12,
    error_count: 1
  },
  health: :healthy,  # :healthy | :degraded | :unhealthy
  timestamp: ~U[2025-01-15 10:30:50Z]
}}
```

**Example:**
```elixir
{:ok, status} = Operations.status()

IO.inspect(status.manager.view_count)
# => 3

IO.inspect(status.health)
# => :healthy
```

---

#### health_check/1

Perform comprehensive health check of the hot-reload system.

**Signature:**
```elixir
@spec health_check(keyword()) :: {:ok, map()}
```

**Parameters:**
- `opts` - Options (`:manager_pid`, `:watcher_pid`)

**Returns:**
```elixir
{:ok, %{
  status: :healthy,  # Overall health
  checks: %{
    manager: :passing,      # :passing | :warning | :failing
    watcher: :passing,      # or :not_applicable
    views: :passing,
    configuration: :passing
  },
  details: %{
    manager: %{status: :passing, message: "ViewManager is operational"},
    watcher: %{status: :passing, message: "ConfigWatcher is active and watching"},
    views: %{status: :passing, message: "Views are configured"},
    configuration: %{status: :passing, message: "Configuration file exists"}
  },
  timestamp: ~U[2025-01-15 10:30:50Z]
}}
```

**Example:**
```elixir
{:ok, health} = Operations.health_check()

case health.status do
  :healthy ->
    IO.puts("System is healthy")
  :degraded ->
    IO.puts("System is degraded: #{inspect(health.details)}")
  :unhealthy ->
    IO.puts("System is unhealthy: #{inspect(health.details)}")
end
```

**Health Status:**
- `:healthy` - All components operational
- `:degraded` - Some warnings but system functional
- `:unhealthy` - Critical components failing

---

### Metrics

#### get_metrics/1

Get comprehensive metrics for monitoring and dashboards.

**Signature:**
```elixir
@spec get_metrics(keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `opts` - Options (`:manager_pid`, `:watcher_pid`)

**Returns:**
```elixir
{:ok, %{
  views: %{
    count: 3,
    names: ["internal", "dmz", "external"]
  },
  reloads: %{
    total: 12,
    successful: 11,
    failed: 1,
    last_reload: ~U[2025-01-15 10:30:45Z]
  },
  operations: %{
    update_count: 5,
    last_update: ~U[2025-01-15 10:30:45Z]
  },
  timestamp: ~U[2025-01-15 10:30:50Z]
}}
```

**Example:**
```elixir
{:ok, metrics} = Operations.get_metrics()

# Calculate success rate
success_rate = metrics.reloads.successful / metrics.reloads.total * 100
IO.puts("Reload success rate: #{success_rate}%")
# => Reload success rate: 91.67%
```

---

### Hot-Reload Control

#### trigger_reload/1

Manually trigger a configuration reload from file.

**Signature:**
```elixir
@spec trigger_reload(keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `opts` - Options (`:watcher_pid`)

**Returns:**
- `{:ok, %{status: :reloaded, triggered_at: timestamp}}` on success
- `{:error, reason}` on failure

**Example:**
```elixir
{:ok, result} = Operations.trigger_reload()
# => {:ok, %{status: :reloaded, triggered_at: ~U[2025-01-15 10:30:50Z]}}
```

**Errors:**
- `:watcher_not_running` - ConfigWatcher is not active
- `{:toml_parse_error, _}` - Configuration file has syntax errors
- `{:duplicate_view_names, names}` - Configuration has duplicate names

---

#### hot_reload_enabled?/0

Check if hot-reload is currently enabled.

**Signature:**
```elixir
@spec hot_reload_enabled?() :: boolean()
```

**Returns:**
- `true` if hot-reload is enabled
- `false` if disabled

**Example:**
```elixir
if Operations.hot_reload_enabled?() do
  IO.puts("Hot-reload is active")
  Operations.trigger_reload()
else
  IO.puts("Hot-reload is disabled")
end
```

---

#### get_config_path/0

Get the current configuration file path being watched.

**Signature:**
```elixir
@spec get_config_path() :: {:ok, String.t()} | {:error, :not_configured}
```

**Returns:**
- `{:ok, path}` - Path to config file
- `{:error, :not_configured}` - No config path set

**Example:**
```elixir
case Operations.get_config_path() do
  {:ok, path} ->
    IO.puts("Watching: #{path}")
  {:error, :not_configured} ->
    IO.puts("Hot-reload not configured")
end
```

---

### Diagnostics

#### list_views/1

List all current views with detailed information.

**Signature:**
```elixir
@spec list_views(keyword()) :: {:ok, [map()]} | {:error, term()}
```

**Parameters:**
- `opts` - Options (`:manager_pid`)

**Returns:**
```elixir
{:ok, [
  %{
    name: "internal",
    match_clients: "localnets",
    zones: ["corp.example.com", "internal.net"],
    recursion_enabled: true,
    zone_count: 2
  },
  %{
    name: "external",
    match_clients: "any",
    zones: ["public.example.com"],
    recursion_enabled: false,
    zone_count: 1
  }
]}
```

**Example:**
```elixir
{:ok, views} = Operations.list_views()

Enum.each(views, fn view ->
  IO.puts("View: #{view.name}")
  IO.puts("  Match: #{view.match_clients}")
  IO.puts("  Zones: #{Enum.join(view.zones, ", ")}")
  IO.puts("  Recursion: #{view.recursion_enabled}")
end)
```

---

#### get_view_info/2

Get detailed information about a specific view.

**Signature:**
```elixir
@spec get_view_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `view_name` - Name of the view
- `opts` - Options (`:manager_pid`)

**Returns:**
```elixir
{:ok, %{
  name: "internal",
  match_clients: "localnets",
  zones: ["corp.example.com"],
  recursion_enabled: true,
  zone_count: 1,
  match_clients_details: %{
    type: :private_networks,
    pattern: "localnets"
  }
}}
```

**Example:**
```elixir
{:ok, info} = Operations.get_view_info("internal")
IO.inspect(info, pretty: true)
```

**Errors:**
- `:view_not_found` - View doesn't exist

---

#### test_client_match/2

Test which view a client IP would match.

**Signature:**
```elixir
@spec test_client_match(:inet.ip_address(), keyword()) :: {:ok, map()} | {:error, term()}
```

**Parameters:**
- `client_ip` - IP address tuple (e.g., `{192, 168, 1, 100}`)
- `opts` - Options (`:manager_pid`)

**Returns:**
```elixir
{:ok, %{
  matched_view: "internal",
  client_ip: "192.168.1.100",
  recursion_enabled: true,
  accessible_zones: ["corp.example.com", "internal.net"]
}}
```

**Example:**
```elixir
# Test internal IP
{:ok, result} = Operations.test_client_match({192, 168, 1, 100})
IO.puts("Internal IP matches: #{result.matched_view}")

# Test external IP
{:ok, result} = Operations.test_client_match({8, 8, 8, 8})
IO.puts("External IP matches: #{result.matched_view}")
```

**Errors:**
- `{:error, %{reason: :no_match, client_ip: ip}}` - No view matches this IP

---

## Usage Examples

### Example 1: Adding a Guest Network View

```elixir
alias YellowDog.Dns.View
alias YellowDog.Dns.View.Operations

# Create guest view
guest_view = View.new(
  "guest_network",
  "10.99.0.0/16",
  ["guest.example.com", "wifi.example.com"],
  true  # recursion enabled
)

# Add to system
case Operations.add_view(guest_view) do
  {:ok, result} ->
    IO.puts("Added guest view. Total views: #{result.total_views}")

  {:error, {:duplicate_view_name, name}} ->
    IO.puts("View '#{name}' already exists. Updating instead...")
    Operations.update_view(name, guest_view)

  {:error, reason} ->
    IO.puts("Failed to add view: #{inspect(reason)}")
end
```

### Example 2: Health Monitoring Loop

```elixir
defmodule DNSMonitor do
  alias YellowDog.Dns.View.Operations

  def start_monitoring(interval_ms \\ 60_000) do
    :timer.apply_interval(interval_ms, __MODULE__, :check_health, [])
  end

  def check_health do
    {:ok, health} = Operations.health_check()

    case health.status do
      :healthy ->
        :ok

      :degraded ->
        Logger.warning("DNS system degraded", health: health.details)
        send_alert(:warning, health)

      :unhealthy ->
        Logger.error("DNS system unhealthy", health: health.details)
        send_alert(:critical, health)
    end
  end

  defp send_alert(level, health) do
    # Send to monitoring system (PagerDuty, Slack, etc.)
    # ...
  end
end

# Start monitoring
DNSMonitor.start_monitoring()
```

### Example 3: Metrics Dashboard

```elixir
defmodule DNSDashboard do
  alias YellowDog.Dns.View.Operations

  def get_dashboard_data do
    {:ok, status} = Operations.status()
    {:ok, metrics} = Operations.get_metrics()
    {:ok, views} = Operations.list_views()

    %{
      status: %{
        health: status.health,
        view_count: status.manager.view_count,
        last_update: status.manager.last_update
      },
      metrics: %{
        reload_success_rate: calculate_success_rate(metrics.reloads),
        total_reloads: metrics.reloads.total,
        operation_count: metrics.operations.update_count
      },
      views: Enum.map(views, fn view ->
        %{
          name: view.name,
          zones: view.zone_count,
          recursion: view.recursion_enabled
        }
      end)
    }
  end

  defp calculate_success_rate(%{successful: s, total: t}) when t > 0 do
    Float.round(s / t * 100, 2)
  end
  defp calculate_success_rate(_), do: 0.0
end
```

### Example 4: Automated View Management

```elixir
defmodule ViewManager do
  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.Operations

  def sync_from_database do
    # Fetch view configuration from database
    db_views = fetch_views_from_db()

    # Convert to View structs
    views = Enum.map(db_views, fn config ->
      View.new(
        config.name,
        config.match_clients,
        config.zones,
        config.recursion_enabled
      )
    end)

    # Replace all views atomically
    case Operations.replace_all_views(views) do
      {:ok, result} ->
        Logger.info("Synced views from database", result)
        :ok

      {:error, reason} ->
        Logger.error("Failed to sync views", reason: reason)
        {:error, reason}
    end
  end

  def add_temporary_view(name, match_clients, duration_minutes) do
    # Add temporary view
    temp_view = View.new(name, match_clients, [], true)
    {:ok, _} = Operations.add_view(temp_view)

    # Schedule removal
    Process.send_after(
      self(),
      {:remove_temp_view, name},
      duration_minutes * 60 * 1000
    )

    :ok
  end

  def handle_info({:remove_temp_view, name}, state) do
    Operations.remove_view(name)
    {:noreply, state}
  end
end
```

### Example 5: Client Testing Tool

```elixir
defmodule ClientTester do
  alias YellowDog.Dns.View.Operations

  def test_subnet(base_ip, count \\ 10) do
    {a, b, c, _} = base_ip

    results = for d <- 1..count do
      ip = {a, b, c, d}

      case Operations.test_client_match(ip) do
        {:ok, result} ->
          %{ip: result.client_ip, view: result.matched_view, recursion: result.recursion_enabled}

        {:error, error} ->
          %{ip: format_ip(ip), error: error.reason}
      end
    end

    # Summarize results
    Enum.group_by(results, & &1[:view])
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end

# Test internal subnet
ClientTester.test_subnet({192, 168, 1, 0}, 20)
# => %{
#   "internal" => [%{ip: "192.168.1.1", view: "internal", ...}, ...],
#   "external" => [%{ip: "192.168.1.254", view: "external", ...}]
# }
```

## Integration

### Phoenix LiveView Dashboard

```elixir
defmodule YellowDogConsoleWeb.DNSOperationsLive do
  use YellowDogConsoleWeb, :live_view
  alias YellowDog.Dns.View.Operations

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update every 5 seconds
      :timer.send_interval(5000, self(), :update_stats)
    end

    socket = load_data(socket)
    {:ok, socket}
  end

  def handle_info(:update_stats, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_event("add_view", %{"view" => view_params}, socket) do
    case add_view_from_params(view_params) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "View added successfully")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp load_data(socket) do
    {:ok, status} = Operations.status()
    {:ok, metrics} = Operations.get_metrics()
    {:ok, views} = Operations.list_views()

    assign(socket,
      status: status,
      metrics: metrics,
      views: views
    )
  end
end
```

### REST API Endpoint

```elixir
defmodule YellowDogWeb.DNSOperationsController do
  use YellowDogWeb, :controller
  alias YellowDog.Dns.View.Operations

  def status(conn, _params) do
    {:ok, status} = Operations.status()
    json(conn, status)
  end

  def health(conn, _params) do
    {:ok, health} = Operations.health_check()

    status_code = case health.status do
      :healthy -> 200
      :degraded -> 200
      :unhealthy -> 503
    end

    conn
    |> put_status(status_code)
    |> json(health)
  end

  def metrics(conn, _params) do
    {:ok, metrics} = Operations.get_metrics()
    json(conn, metrics)
  end

  def list_views(conn, _params) do
    {:ok, views} = Operations.list_views()
    json(conn, views)
  end

  def test_client(conn, %{"ip" => ip_string}) do
    with {:ok, ip} <- parse_ip(ip_string),
         {:ok, result} <- Operations.test_client_match(ip) do
      json(conn, result)
    else
      {:error, error} ->
        conn
        |> put_status(400)
        |> json(%{error: error})
    end
  end
end
```

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `:view_not_found` | View doesn't exist | Check view name spelling |
| `{:duplicate_view_name, name}` | View name already exists | Use `update_view` instead of `add_view` |
| `:cannot_remove_last_view` | Trying to remove only view | Add another view first |
| `{:name_mismatch, _, _}` | Updated view has different name | Ensure view name matches |
| `:watcher_not_running` | ConfigWatcher not started | Enable hot-reload or start watcher |
| `{:manager_error, _}` | ViewManager unavailable | Check if manager is running |

### Error Handling Pattern

```elixir
case Operations.add_view(view) do
  {:ok, result} ->
    # Success
    handle_success(result)

  {:error, {:duplicate_view_name, name}} ->
    # Specific error handling
    IO.puts("View #{name} already exists")

  {:error, reason} ->
    # Generic error handling
    Logger.error("Operation failed: #{inspect(reason)}")
    {:error, reason}
end
```

## Best Practices

### 1. Always Check Health Before Operations

```elixir
defmodule SafeOperations do
  alias YellowDog.Dns.View.Operations

  def safe_add_view(view) do
    with {:ok, health} <- Operations.health_check(),
         :healthy <- health.status,
         {:ok, result} <- Operations.add_view(view) do
      {:ok, result}
    else
      status when status in [:degraded, :unhealthy] ->
        {:error, {:unhealthy_system, status}}
      error ->
        error
    end
  end
end
```

### 2. Use Transactions for Multiple Operations

```elixir
def update_views_transaction(updates) do
  # Save current state
  {:ok, current_views} = Operations.list_views()

  try do
    Enum.each(updates, fn {name, new_view} ->
      case Operations.update_view(name, new_view) do
        {:ok, _} -> :ok
        {:error, reason} -> throw({:rollback, reason})
      end
    end)

    :ok
  catch
    {:rollback, reason} ->
      # Rollback by restoring original views
      # (Note: actual implementation would need to store View structs)
      Logger.error("Transaction failed, rolling back: #{inspect(reason)}")
      {:error, reason}
  end
end
```

### 3. Monitor Metrics Over Time

```elixir
defmodule MetricsCollector do
  use GenServer
  alias YellowDog.Dns.View.Operations

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_collection()
    {:ok, %{history: []}}
  end

  def handle_info(:collect, state) do
    {:ok, metrics} = Operations.get_metrics()

    data_point = %{
      timestamp: DateTime.utc_now(),
      view_count: metrics.views.count,
      reload_success_rate: calculate_rate(metrics.reloads),
      operation_count: metrics.operations.update_count
    }

    # Store in time-series database
    store_metrics(data_point)

    schedule_collection()
    {:noreply, %{state | history: [data_point | state.history] |> Enum.take(1000)}}
  end

  defp schedule_collection do
    Process.send_after(self(), :collect, 60_000)  # Every minute
  end
end
```

### 4. Validate Before Applying

```elixir
def safe_replace_views(new_views) do
  # Validate structure
  if Enum.all?(new_views, &is_struct(&1, View)) do
    # Check for duplicates
    names = Enum.map(new_views, & &1.name)
    unique_names = Enum.uniq(names)

    if length(names) == length(unique_names) do
      Operations.replace_all_views(new_views)
    else
      {:error, :duplicate_names}
    end
  else
    {:error, :invalid_view_type}
  end
end
```

### 5. Log All Operations

```elixir
defmodule AuditedOperations do
  alias YellowDog.Dns.View.Operations
  require Logger

  def add_view(view, user_id) do
    result = Operations.add_view(view)

    Logger.metadata(user_id: user_id, operation: :add_view, view_name: view.name)

    case result do
      {:ok, _} -> Logger.info("View added successfully")
      {:error, reason} -> Logger.error("View add failed: #{inspect(reason)}")
    end

    result
  end
end
```

## Related Documentation

- [Hot-Reload System](./HOT_RELOAD.md)
- [DNS Views Configuration](./DNS_VIEWS.md)
- [Telemetry Guide](./TELEMETRY.md)
- [API Integration Guide](./API_INTEGRATION.md)

## Support

For issues or questions:
- Check health: `Operations.health_check()`
- Review metrics: `Operations.get_metrics()`
- Test configuration: `Operations.test_client_match(ip)`
- File issues: GitHub repository
