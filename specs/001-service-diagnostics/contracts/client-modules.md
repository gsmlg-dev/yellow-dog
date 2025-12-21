# Client Module Contracts: Service Diagnostics

**Date**: 2025-12-19
**Branch**: `001-service-diagnostics`

This document defines the internal module contracts for protocol client implementations.

## Module: YellowDog.Console.Diagnostics.DnsClient

### query/1

Sends a DNS query and returns the result.

```elixir
@spec query(params :: map()) :: {:ok, QueryResult.t()} | {:error, term()}

# Input params
%{
  query_name: String.t(),
  record_type: atom(),
  server: String.t(),
  port: pos_integer(),
  protocol: :udp | :tcp,
  recursion_desired: boolean(),
  timeout: pos_integer()
}

# Success return
{:ok, %QueryResult{
  id: String.t(),
  timestamp: DateTime.t(),
  params: map(),
  request_binary: binary(),
  request_struct: %DNS.Message{},
  response_binary: binary(),
  response_struct: %DNS.Message{},
  latency_ms: non_neg_integer(),
  status: :success
}}

# Error returns
{:error, :timeout}
{:error, {:socket_error, reason}}
{:error, {:parse_error, reason}}
```

---

## Module: YellowDog.Console.Diagnostics.MdnsClient

### query/1

Sends an mDNS multicast query and collects responses until timeout.

```elixir
@spec query(params :: map()) :: {:ok, QueryResult.t()} | {:error, term()}

# Input params
%{
  service_type: String.t(),
  query_type: atom(),
  timeout: pos_integer()
}

# Success return (multiple responses)
{:ok, %QueryResult{
  id: String.t(),
  timestamp: DateTime.t(),
  params: map(),
  request_binary: binary(),
  request_struct: %DNS.Message{},
  response_binary: nil,  # Multiple responses, see sources
  response_struct: nil,
  sources: [
    %{
      address: tuple(),  # e.g., {192, 168, 1, 100}
      port: pos_integer(),
      response_binary: binary(),
      response_struct: %DNS.Message{}
    }
  ],
  latency_ms: non_neg_integer(),  # Time until timeout
  status: :success
}}

# No responses (still success, empty sources)
{:ok, %QueryResult{sources: [], status: :success}}

# Error returns
{:error, {:socket_error, reason}}
```

---

## Module: YellowDog.Console.Diagnostics.Dhcpv4Client

### query/1

Sends a DHCPv4 broadcast message and waits for response.

```elixir
@spec query(params :: map()) :: {:ok, QueryResult.t()} | {:error, term()}

# Input params
%{
  message_type: :discover | :request | :decline | :release | :inform,
  client_mac: String.t(),         # "xx:xx:xx:xx:xx:xx" or auto-generated
  transaction_id: String.t() | nil,  # Hex string or auto-generated
  requested_options: [pos_integer()],
  timeout: pos_integer()
}

# Success return
{:ok, %QueryResult{
  id: String.t(),
  timestamp: DateTime.t(),
  params: map(),
  request_binary: binary(),
  request_struct: %DHCPv4.Message{},
  response_binary: binary(),
  response_struct: %DHCPv4.Message{},
  latency_ms: non_neg_integer(),
  status: :success
}}

# Error returns
{:error, :timeout}
{:error, {:socket_error, :eacces}}  # Port 68 requires root
{:error, {:socket_error, reason}}
{:error, {:parse_error, reason}}
```

### Privileged Port Warning

```elixir
@spec requires_privileged_port?() :: boolean()
# Always returns true - port 68 requires root/admin
```

---

## Module: YellowDog.Console.Diagnostics.Dhcpv6Client

### query/1

Sends a DHCPv6 multicast message and waits for response.

```elixir
@spec query(params :: map()) :: {:ok, QueryResult.t()} | {:error, term()}

# Input params
%{
  message_type: :solicit | :request | :renew | :rebind | :release | :decline | :information_request,
  duid: String.t() | nil,           # Hex string or auto-generated
  transaction_id: String.t() | nil, # Hex string or auto-generated
  iaid: String.t() | nil,           # Hex string or auto-generated
  requested_options: [pos_integer()],
  timeout: pos_integer()
}

# Success return
{:ok, %QueryResult{
  id: String.t(),
  timestamp: DateTime.t(),
  params: map(),
  request_binary: binary(),
  request_struct: %DHCPv6.Message{},
  response_binary: binary(),
  response_struct: %DHCPv6.Message{},
  latency_ms: non_neg_integer(),
  status: :success
}}

# Error returns
{:error, :timeout}
{:error, {:socket_error, :eacces}}  # Port 546 requires root
{:error, {:socket_error, reason}}
{:error, {:parse_error, reason}}
```

### Privileged Port Warning

```elixir
@spec requires_privileged_port?() :: boolean()
# Always returns true - port 546 requires root/admin
```

---

## Module: YellowDog.Console.Diagnostics.HexFormatter

### format/1

Formats binary data as xxd-style hex dump.

```elixir
@spec format(binary()) :: String.t()

# Input
<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

# Output
"""
00000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  ................
00000010: 10                                               .
"""
```

### format_inline/1

Formats binary as space-separated hex bytes (for short values).

```elixir
@spec format_inline(binary()) :: String.t()

# Input
<<192, 168, 1, 1>>

# Output
"c0 a8 01 01"
```

---

## Shared Types

### QueryResult

```elixir
defmodule YellowDog.Console.Diagnostics.QueryResult do
  @type t :: %__MODULE__{
    id: String.t(),
    timestamp: DateTime.t(),
    params: map(),
    request_binary: binary(),
    request_struct: struct() | nil,
    response_binary: binary() | nil,
    response_struct: struct() | nil,
    sources: [map()],
    latency_ms: non_neg_integer(),
    status: :success | :timeout | :error,
    error: String.t() | nil
  }
end
```

---

## Error Handling Contract

All client modules follow this error handling pattern:

```elixir
def query(params) do
  start_time = System.monotonic_time(:millisecond)

  with {:ok, socket} <- open_socket(params),
       {:ok, request} <- build_request(params),
       :ok <- send_request(socket, request),
       {:ok, response} <- receive_response(socket, params.timeout) do
    latency = System.monotonic_time(:millisecond) - start_time
    close_socket(socket)
    {:ok, build_result(params, request, response, latency)}
  else
    {:error, :timeout} ->
      {:error, :timeout}

    {:error, reason} ->
      {:error, {:socket_error, reason}}
  end
rescue
  e in [ArgumentError, MatchError] ->
    {:error, {:parse_error, Exception.message(e)}}
end
```
