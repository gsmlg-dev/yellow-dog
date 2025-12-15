# Service Control API Contract

**Branch**: `001-dns-service` | **Date**: 2025-12-10

## Overview

This document defines the internal Elixir API contract for service control. These are not HTTP APIs but Elixir function interfaces used by the dashboard and other internal components.

---

## Module: `YellowDog`

Public API module that delegates to ServiceManager.

### `start_service/1`

Starts a YellowDog service.

**Signature**:
```elixir
@spec start_service(atom()) :: :ok | {:error, term()}
```

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `service` | `atom` | Yes | Service identifier: `:dns`, `:mdns`, `:dhcpv4`, or `:dhcpv6` |

**Returns**:
| Result | Description |
|--------|-------------|
| `:ok` | Service started successfully |
| `{:error, {:already_started, pid}}` | Service already running |
| `{:error, :invalid_service}` | Unknown service identifier |
| `{:error, :port_in_use}` | Service port unavailable |
| `{:error, :permission_denied}` | Insufficient privileges for port |
| `{:error, term()}` | Other startup error |

**Example**:
```elixir
iex> YellowDog.start_service(:dns)
:ok

iex> YellowDog.start_service(:dns)
{:error, {:already_started, #PID<0.123.0>}}

iex> YellowDog.start_service(:invalid)
{:error, :invalid_service}
```

---

### `stop_service/1`

Stops a YellowDog service.

**Signature**:
```elixir
@spec stop_service(atom()) :: :ok | {:error, term()}
```

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `service` | `atom` | Yes | Service identifier: `:dns`, `:mdns`, `:dhcpv4`, or `:dhcpv6` |

**Returns**:
| Result | Description |
|--------|-------------|
| `:ok` | Service stopped successfully |
| `{:error, :not_running}` | Service not currently running |
| `{:error, :invalid_service}` | Unknown service identifier |
| `{:error, term()}` | Other shutdown error |

**Example**:
```elixir
iex> YellowDog.stop_service(:dns)
:ok

iex> YellowDog.stop_service(:dns)
{:error, :not_running}
```

---

### `get_all_status/0`

Gets status of all services.

**Signature**:
```elixir
@spec get_all_status() :: map()
```

**Returns**:
```elixir
%{
  dns: %{
    enabled: boolean(),
    running: boolean(),
    uptime: String.t() | nil,
    config: map(),
    stats: map() | nil,
    error: String.t() | nil
  },
  mdns: %{...},
  dhcpv4: %{...},
  dhcpv6: %{...}
}
```

**Example**:
```elixir
iex> YellowDog.get_all_status()
%{
  dns: %{
    enabled: true,
    running: true,
    uptime: "1h 23m 45s",
    config: %{listen: "0.0.0.0", port: 53},
    stats: %{queries: 1234},
    error: nil
  },
  mdns: %{enabled: true, running: true, ...},
  dhcpv4: %{enabled: false, running: false, ...},
  dhcpv6: %{enabled: false, running: false, ...}
}
```

---

### `get_service_status/1`

Gets status of a specific service.

**Signature**:
```elixir
@spec get_service_status(atom()) :: map()
```

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `service` | `atom` | Yes | Service identifier |

**Returns**:
```elixir
%{
  enabled: boolean(),
  running: boolean(),
  uptime: String.t() | nil,
  config: map(),
  stats: map() | nil,
  error: String.t() | nil
}
```

---

## Module: `YellowDog.Dns.Supervisor`

DNS service supervisor module.

### `start_link/1`

Starts the DNS supervisor.

**Current (Broken) Signature**:
```elixir
@spec start_link(keyword()) :: Supervisor.on_start() | :ignore
```

**Proposed (Fixed) Signature**:
```elixir
@spec start_link(keyword()) :: Supervisor.on_start()
```

**Change**: Remove `:ignore` return path. Application layer handles disabled services.

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `opts` | `keyword` | No | Supervisor options |

**Returns**:
| Result | Description |
|--------|-------------|
| `{:ok, pid}` | Supervisor started |
| `{:error, {:already_started, pid}}` | Already running |
| `{:error, term}` | Startup failed |

---

## LiveView Events

### Event: `"start_service"`

Triggered when user clicks Start button.

**Parameters**:
```elixir
%{"service" => "dns"}  # String service name
```

**Handler Contract**:
```elixir
def handle_event("start_service", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)

  case YellowDog.start_service(service) do
    :ok ->
      {:noreply,
       socket
       |> assign(:services, get_service_status())
       |> put_flash(:info, "Service started successfully")}

    {:error, reason} ->
      {:noreply,
       put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
  end
end
```

---

### Event: `"stop_service"`

Triggered when user clicks Stop button.

**Parameters**:
```elixir
%{"service" => "dns"}  # String service name
```

**Handler Contract**:
```elixir
def handle_event("stop_service", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)

  case YellowDog.stop_service(service) do
    :ok ->
      {:noreply,
       socket
       |> assign(:services, get_service_status())
       |> put_flash(:info, "Service stopped successfully")}

    {:error, reason} ->
      {:noreply,
       put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
  end
end
```

---

## Error Codes

| Code | Description | User Message |
|------|-------------|--------------|
| `:already_started` | Service already running | "Service is already running" |
| `:not_running` | Service not running | "Service is not running" |
| `:invalid_service` | Unknown service | "Unknown service" |
| `:port_in_use` | Port unavailable | "Port is already in use" |
| `:permission_denied` | Need elevated privileges | "Permission denied. Run with elevated privileges" |
| `:timeout` | Operation timed out | "Operation timed out" |
| `:supervisor_error` | Supervisor startup failed | "Failed to start supervisor: {details}" |
