# LiveView Events Contract: Service Diagnostics

**Date**: 2025-12-19
**Branch**: `001-service-diagnostics`

This document defines the client-server event contract for the diagnostics LiveView.

## Client Events (phx-click, phx-submit, phx-change)

### Tab Navigation

**Event**: `select_tab`
```elixir
# Payload
%{"tab" => "dns" | "mdns" | "dhcpv4" | "dhcpv6"}

# Handler
def handle_event("select_tab", %{"tab" => tab}, socket)
```

### Display Mode Toggle

**Event**: `toggle_display_mode`
```elixir
# Payload
%{"mode" => "struct" | "raw"}

# Handler
def handle_event("toggle_display_mode", %{"mode" => mode}, socket)
```

### Form Validation

**Event**: `validate`
```elixir
# Payload (varies by tab)
%{"dns_query" => %{"query_name" => "...", "record_type" => "a", ...}}
%{"mdns_query" => %{"service_type" => "...", ...}}
%{"dhcpv4_query" => %{"message_type" => "discover", ...}}
%{"dhcpv6_query" => %{"message_type" => "solicit", ...}}

# Handler
def handle_event("validate", params, socket)
```

### Send Query

**Event**: `send_query`
```elixir
# Payload (same structure as validate)
%{"dns_query" => %{...}}
# etc.

# Handler
def handle_event("send_query", params, socket)
# Starts async query execution
```

### History Actions

**Event**: `select_history`
```elixir
# Payload
%{"id" => "query-uuid"}

# Handler
def handle_event("select_history", %{"id" => id}, socket)
# Restores form and result from history entry
```

**Event**: `clear_history`
```elixir
# Payload (none)

# Handler
def handle_event("clear_history", _params, socket)
# Clears history for current tab
```

**Event**: `toggle_history`
```elixir
# Payload (none)

# Handler
def handle_event("toggle_history", _params, socket)
# Toggles history panel visibility
```

### Copy to Clipboard

**Event**: `copy_request` / `copy_response`
```elixir
# These are handled via JavaScript hooks, not LiveView events
# The JS hook calls navigator.clipboard.writeText()
# Then pushes "copied" event for flash notification

# Handler
def handle_event("copied", _params, socket)
# Shows "Copied to clipboard" flash
```

## Server Events (handle_async)

### Query Completion

**Async name**: `:query`
```elixir
# Success result
def handle_async(:query, {:ok, result}, socket)
# result = %QueryResult{status: :success, ...}

# Exit/error result
def handle_async(:query, {:exit, reason}, socket)
# Handles timeout, socket errors, parse failures
```

## Event Flow Diagrams

### Send DNS Query

```
User clicks "Send"
    │
    ▼
handle_event("send_query", %{"dns_query" => params})
    │
    ├── Validate form
    │   └── If invalid: {:noreply, assign_errors(socket)}
    │
    ├── Build DNS.Message
    │
    ├── assign(:loading, true)
    │
    └── start_async(:query, fn -> execute_dns_query(params) end)
        │
        ▼
    [Async execution]
        │
        ├── Open socket
        ├── Send query
        ├── Wait for response (with timeout)
        ├── Parse response
        └── Return {result, latency}
            │
            ▼
    handle_async(:query, {:ok, result})
        │
        ├── assign(:loading, false)
        ├── assign_result(result)
        └── add_to_history(result)
```

### Select from History

```
User clicks history entry
    │
    ▼
handle_event("select_history", %{"id" => id})
    │
    ├── Find entry in history
    │
    ├── Restore form params
    │
    └── Display stored result
```

## Form Field Mappings

### DNS Query Form

| Form Field | Param Key | Type | Default |
|------------|-----------|------|---------|
| Query Name | `query_name` | string | `""` |
| Record Type | `record_type` | string (atom name) | `"a"` |
| Server | `server` | string (IP) | `"127.0.0.1"` |
| Port | `port` | string (integer) | `"53"` |
| Protocol | `protocol` | string | `"udp"` |
| Recursion | `recursion_desired` | string (boolean) | `"true"` |
| Timeout | `timeout` | string (integer ms) | `"5000"` |

### mDNS Query Form

| Form Field | Param Key | Type | Default |
|------------|-----------|------|---------|
| Service Type | `service_type` | string | `"_http._tcp.local"` |
| Query Type | `query_type` | string (atom name) | `"ptr"` |
| Timeout | `timeout` | string (integer ms) | `"3000"` |

### DHCPv4 Query Form

| Form Field | Param Key | Type | Default |
|------------|-----------|------|---------|
| Message Type | `message_type` | string | `"discover"` |
| Client MAC | `client_mac` | string (xx:xx:...) | `""` (auto-gen) |
| Transaction ID | `transaction_id` | string (hex) | `""` (auto-gen) |
| Options | `requested_options` | string (comma-sep) | `"1,3,6,15"` |
| Timeout | `timeout` | string (integer ms) | `"10000"` |

### DHCPv6 Query Form

| Form Field | Param Key | Type | Default |
|------------|-----------|------|---------|
| Message Type | `message_type` | string | `"solicit"` |
| DUID | `duid` | string (hex) | `""` (auto-gen) |
| Transaction ID | `transaction_id` | string (hex) | `""` (auto-gen) |
| IAID | `iaid` | string (hex) | `""` (auto-gen) |
| Options | `requested_options` | string (comma-sep) | `"23"` |
| Timeout | `timeout` | string (integer ms) | `"10000"` |

## Error Responses

All error states are communicated via socket assigns:

```elixir
# Form validation errors
socket = assign(socket, :form_errors, %{query_name: ["is required"]})

# Query execution errors
socket = socket
  |> assign(:current_result, %QueryResult{status: :error, error: "Connection refused"})
  |> put_flash(:error, "Query failed: Connection refused")
```

## JavaScript Hooks

### CopyToClipboard

```javascript
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const target = this.el.dataset.target;
      const content = document.getElementById(target).textContent;
      navigator.clipboard.writeText(content).then(() => {
        this.pushEvent("copied", {});
      }).catch(err => {
        console.error("Copy failed:", err);
      });
    });
  }
}
```

### ThemeToggle (existing)

Already implemented in the codebase for dark mode support.
