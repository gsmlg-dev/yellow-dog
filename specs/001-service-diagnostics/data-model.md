# Data Model: Service Diagnostics Page

**Date**: 2025-12-19
**Branch**: `001-service-diagnostics`

## Overview

The diagnostics page uses LiveView assigns for state management. No persistent storage is required - all data is session-scoped and lives in memory.

## Entities

### DiagnosticsState

Top-level state structure managed in LiveView assigns.

```elixir
%{
  # Current active tab
  active_tab: :dns | :mdns | :dhcpv4 | :dhcpv6,

  # Per-tab state (keyed by tab atom)
  tabs: %{
    dns: %TabState{},
    mdns: %TabState{},
    dhcpv4: %TabState{},
    dhcpv6: %TabState{}
  },

  # Global display mode (shared across tabs)
  display_mode: :struct | :raw
}
```

### TabState

State for each protocol tab.

```elixir
defmodule YellowDog.Console.Diagnostics.TabState do
  defstruct [
    # Form state (protocol-specific fields)
    form: %{},

    # Current query in progress
    loading: false,

    # Current result (nil if no query sent yet)
    current_result: nil,

    # Query history (max 10 entries, newest first)
    history: []
  ]
end
```

### QueryResult

Represents a completed query with request/response data.

```elixir
defmodule YellowDog.Console.Diagnostics.QueryResult do
  defstruct [
    # Unique identifier
    id: nil,

    # When the query was sent
    timestamp: nil,

    # Query parameters (for re-selection from history)
    params: %{},

    # Request data
    request_binary: <<>>,
    request_struct: nil,

    # Response data (nil if timeout/error)
    response_binary: nil,
    response_struct: nil,

    # Source address for mDNS (list of {address, response} for multiple)
    sources: [],

    # Latency in milliseconds
    latency_ms: 0,

    # Status
    status: :success | :timeout | :error,

    # Error message (if status is :error)
    error: nil
  ]
end
```

### Protocol-Specific Form Fields

#### DNS Form

```elixir
%{
  query_name: "example.com",
  record_type: :a,                    # :a | :aaaa | :mx | :txt | :cname | :ns | :soa | :ptr | :srv
  server: "127.0.0.1",
  port: 53,
  protocol: :udp,                     # :udp | :tcp
  recursion_desired: true,
  timeout: 5000                       # milliseconds
}
```

#### mDNS Form

```elixir
%{
  service_type: "_http._tcp.local",
  query_type: :ptr,                   # :ptr | :srv | :txt | :a | :aaaa
  timeout: 3000                       # milliseconds
}
```

#### DHCPv4 Form

```elixir
%{
  message_type: :discover,            # :discover | :request | :decline | :release | :inform
  client_mac: "00:11:22:33:44:55",    # String format, converted to binary
  transaction_id: nil,                # nil = auto-generate
  requested_options: [1, 3, 6, 15],   # Option codes to request
  timeout: 10000                      # milliseconds
}
```

#### DHCPv6 Form

```elixir
%{
  message_type: :solicit,             # :solicit | :request | :renew | :rebind | :release | :decline | :information_request
  duid: nil,                          # nil = auto-generate, or hex string
  transaction_id: nil,                # nil = auto-generate
  iaid: nil,                          # nil = auto-generate
  requested_options: [23],            # Option codes (23 = DNS servers)
  timeout: 10000                      # milliseconds
}
```

## State Transitions

### Query Lifecycle

```
IDLE -> LOADING -> SUCCESS/TIMEOUT/ERROR -> IDLE
```

1. **IDLE**: Form ready, no query in progress
2. **LOADING**: Query sent, waiting for response
3. **SUCCESS**: Response received and parsed
4. **TIMEOUT**: No response within timeout
5. **ERROR**: Socket error or parse failure

### History Management

```elixir
defp add_to_history(history, result) do
  [result | history]
  |> Enum.take(10)
end

defp restore_from_history(tab_state, result_id) do
  case Enum.find(tab_state.history, &(&1.id == result_id)) do
    nil -> tab_state
    result -> %{tab_state | form: result.params, current_result: result}
  end
end
```

## Validation Rules

### DNS Form Validation

| Field | Validation |
|-------|------------|
| query_name | Required, valid domain format |
| record_type | Required, one of supported types |
| server | Required, valid IP address |
| port | Required, 1-65535 |
| protocol | Required, :udp or :tcp |
| timeout | Required, 1000-30000 ms |

### mDNS Form Validation

| Field | Validation |
|-------|------------|
| service_type | Required, should end with ".local" |
| query_type | Required, one of supported types |
| timeout | Required, 1000-30000 ms |

### DHCPv4 Form Validation

| Field | Validation |
|-------|------------|
| message_type | Required, one of supported types |
| client_mac | Required, valid MAC format (xx:xx:xx:xx:xx:xx) |
| timeout | Required, 1000-60000 ms |

### DHCPv6 Form Validation

| Field | Validation |
|-------|------------|
| message_type | Required, one of supported types |
| timeout | Required, 1000-60000 ms |

## Display Modes

### Struct View

Pretty-printed Elixir struct using `inspect(struct, pretty: true, limit: :infinity)`.

### Raw View

xxd-style hex dump with:
- 8-character hex offset
- 16 bytes per line in hex
- ASCII sidebar (printable chars or `.`)

Example:
```
00000000: 00 01 01 00 00 01 00 00 00 00 00 00 07 65 78 61  .............exa
00000010: 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01           mple.com.....
```

## Relationships

```
DiagnosticsState
├── active_tab (atom)
├── display_mode (atom)
└── tabs (map)
    ├── :dns -> TabState
    │   ├── form (DNS form fields)
    │   ├── current_result -> QueryResult
    │   └── history -> [QueryResult]
    ├── :mdns -> TabState
    │   ├── form (mDNS form fields)
    │   ├── current_result -> QueryResult (with multiple sources)
    │   └── history -> [QueryResult]
    ├── :dhcpv4 -> TabState
    │   ├── form (DHCPv4 form fields)
    │   ├── current_result -> QueryResult
    │   └── history -> [QueryResult]
    └── :dhcpv6 -> TabState
        ├── form (DHCPv6 form fields)
        ├── current_result -> QueryResult
        └── history -> [QueryResult]
```

## Memory Considerations

- Each QueryResult stores request and response binaries (~1-4 KB typical)
- 10 entries per tab × 4 tabs = 40 max results
- Estimated max memory: ~200 KB per session
- State is garbage collected when LiveView process terminates
