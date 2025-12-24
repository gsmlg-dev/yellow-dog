# Data Model: Real-time Logs Page

**Date**: 2025-12-24
**Feature**: 001-realtime-logs-page

## Overview

This feature uses in-memory data structures within LiveView assigns. No persistent storage is required as logs are real-time only.

---

## Entities

### 1. LogEntry

Represents a single log event received from telemetry.

```elixir
%{
  id: String.t(),           # Unique ID (UUID or monotonic counter)
  timestamp: DateTime.t(),  # When the log was received
  level: atom(),            # :debug | :info | :warning | :error
  app: atom(),              # Source app: :yellow_dog_dns | :yellow_dog_dhcpv4 | etc.
  module: atom(),           # e.g., YellowDog.Dns.Handler.UDP
  function: String.t(),     # e.g., "handle_data/2"
  message: String.t(),      # The log message
  metadata: map()           # Additional key-value pairs from telemetry
}
```

**Validation Rules**:
- `level` must be one of `:debug`, `:info`, `:warning`, `:error`
- `app` must be a known YellowDog application atom
- `message` must be a string (not nil)

**Source**: Built from telemetry event metadata in `[:yellow_dog, :log, level]` events

---

### 2. FilterState

The current filter configuration for log display.

```elixir
%{
  selected_apps: MapSet.t(atom()),  # Set of selected app filters (empty = show all)
  min_level: atom(),                # Minimum log level to display
  paused: boolean(),                # Whether streaming is paused
  search_term: String.t() | nil     # Optional text search (future enhancement)
}
```

**Default State**:
```elixir
%{
  selected_apps: MapSet.new(),  # Empty = all apps shown
  min_level: :debug,            # Show all levels by default
  paused: false,
  search_term: nil
}
```

**State Transitions**:
- `toggle_app(app)` → Add/remove app from selected_apps
- `set_min_level(level)` → Update min_level
- `toggle_pause()` → Toggle paused boolean
- `clear_filters()` → Reset to defaults

---

### 3. LogBuffer

The collection of log entries currently displayed and buffered.

```elixir
%{
  logs: [LogEntry.t()],          # Displayed log entries (newest first)
  pending_logs: [LogEntry.t()],  # Buffered entries when paused or batching
  max_size: integer(),           # Maximum buffer size (default: 1000)
  pending_count: integer()       # Count of buffered entries for UI display
}
```

**Operations**:
- `add_log(buffer, entry)` → Prepend entry, trim to max_size
- `buffer_log(buffer, entry)` → Add to pending_logs
- `flush_pending(buffer)` → Merge pending into logs, clear pending
- `clear(buffer)` → Empty logs list

**Eviction Policy**: FIFO (First In, First Out) - oldest entries dropped when max_size exceeded

---

## LiveView Assigns Structure

Complete socket assigns for the logs page:

```elixir
socket.assigns = %{
  # Page metadata
  page_title: "Logs",

  # Log data
  logs: [LogEntry.t()],           # Current displayed logs
  pending_logs: [LogEntry.t()],   # Buffered logs (when paused)
  pending_count: integer(),       # For UI badge

  # Filter state
  selected_apps: MapSet.t(),      # Selected app filters
  min_level: atom(),              # Minimum level filter
  paused: boolean(),              # Stream paused?

  # UI state
  expanded_log_id: String.t() | nil,  # Currently expanded log entry (for metadata view)

  # Constants
  available_apps: [
    {:yellow_dog_dns, "DNS"},
    {:yellow_dog_dhcpv4, "DHCPv4"},
    {:yellow_dog_dhcpv6, "DHCPv6"},
    {:yellow_dog_mdns, "mDNS"},
    {:yellow_dog_console, "Console"},
    {:yellow_dog, "Core"}
  ],
  available_levels: [:debug, :info, :warning, :error]
}
```

---

## Message Flow

### Incoming Log Event

```
Telemetry Event
    ↓
LogBroadcaster (GenServer)
    ↓ Phoenix.PubSub.broadcast/3
PubSub "logs:stream" topic
    ↓ {:log_event, level, measurements, metadata}
LogsLive.handle_info/2
    ↓ (filter check)
    ↓ (build LogEntry)
    ↓ (add to buffer)
Socket assigns updated
    ↓
LiveView re-renders
```

### Filter Change

```
User clicks filter checkbox
    ↓ phx-click="toggle_app" or phx-change="set_level"
LogsLive.handle_event/3
    ↓ Update socket.assigns
    ↓ Apply filter to existing logs
LiveView re-renders (filtered view)
```

---

## Level Priority Constants

```elixir
@level_priority %{
  debug: 0,
  info: 1,
  warning: 2,
  error: 3
}

@level_colors %{
  debug: "text-base-content/60",     # Gray
  info: "text-info",                  # Blue
  warning: "text-warning",            # Amber
  error: "text-error"                 # Red
}

@level_badges %{
  debug: "badge-ghost",
  info: "badge-info",
  warning: "badge-warning",
  error: "badge-error"
}
```

---

## App Display Mapping

```elixir
@app_display_names %{
  yellow_dog_dns: "DNS",
  yellow_dog_dhcpv4: "DHCPv4",
  yellow_dog_dhcpv6: "DHCPv6",
  yellow_dog_mdns: "mDNS",
  yellow_dog_console: "Console",
  yellow_dog: "Core"
}

@app_colors %{
  yellow_dog_dns: "badge-primary",
  yellow_dog_dhcpv4: "badge-secondary",
  yellow_dog_dhcpv6: "badge-accent",
  yellow_dog_mdns: "badge-success",
  yellow_dog_console: "badge-warning",
  yellow_dog: "badge-info"
}
```

---

## Buffer Size Limits

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| max_logs | 1000 | Balance between visibility and memory |
| max_pending | 500 | Prevent unbounded growth when paused |
| batch_interval_ms | 100 | Smooth updates without overwhelming browser |
| max_batch_size | 100 | Rate limit for display |
