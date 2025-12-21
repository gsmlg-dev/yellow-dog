# Research: Service Diagnostics Page

**Date**: 2025-12-19
**Branch**: `001-service-diagnostics`

## DNS Protocol Library (ex_dns)

### Decision
Use `DNS.Message` struct with `DNS.to_iodata/1` for serialization and `DNS.Message.from_iodata/1` for parsing.

### Rationale
The ex_dns library provides a complete, production-ready DNS protocol implementation already integrated in the umbrella. The E2E test client (`E2ETest.DnsClient`) provides a working reference for DNS query execution.

### Key Findings

**Message Creation Pattern:**
```elixir
message = %DNS.Message{
  header: %DNS.Message.Header{
    id: DNS.Message.Header.generate_id(),
    qr: 0,                              # Query
    opcode: DNS.Message.OpCode.new(0),  # Standard query
    rd: 1,                              # Recursion desired
    qdcount: 1,
    ancount: 0, nscount: 0, arcount: 0
  },
  qdlist: [DNS.Message.Question.new(domain, record_type, :in)],
  anlist: [], nslist: [], arlist: []
}
```

**Serialization/Parsing:**
```elixir
# Serialize: DNS.to_iodata(message) |> IO.iodata_to_binary()
# Parse: DNS.Message.from_iodata(binary)
```

**Supported Record Types:**
- A (1), AAAA (28), MX (15), TXT (16), CNAME (5), NS (2), SOA (6), PTR (12), SRV (33)
- Plus 15+ additional types including DNSSEC records

### Alternatives Considered
- Direct `:inet_res` - Lower-level, no struct representation
- Third-party libraries - Would add external dependencies

---

## DHCP Protocol Library (ex_dhcp)

### Decision
Use `DHCPv4.Client` and `DHCPv6.Client` modules for message creation, `DHCP.to_iodata/1` for serialization.

### Rationale
The ex_dhcp library provides convenient client utilities specifically designed for creating test messages. The `DHCPv4.Client.discover/1`, `DHCPv6.Client.solicit/1` etc. handle all the boilerplate.

### Key Findings

**DHCPv4 Client Utilities:**
```elixir
# DISCOVER
DHCPv4.Client.discover(mac: <<0, 1, 2, 3, 4, 5>>)

# REQUEST
DHCPv4.Client.request(
  mac: mac_binary,
  server_ip: {192, 168, 1, 1},
  requested_ip: {192, 168, 1, 100}
)

# Message types: DISCOVER (1), REQUEST (3), DECLINE (4), RELEASE (7), INFORM (8)
```

**DHCPv6 Client Utilities:**
```elixir
# SOLICIT
DHCPv6.Client.solicit(duid: duid_binary, iaid: iaid_value)

# REQUEST
DHCPv6.Client.request(
  duid: client_duid,
  server_duid: server_duid,
  iaid: iaid
)

# Message types: SOLICIT (1), REQUEST (3), RENEW (5), REBIND (6), RELEASE (8),
#                DECLINE (9), INFORMATION-REQUEST (11)
```

**Secure Random Generation:**
```elixir
DHCP.SecureRandom.generate_dhcpv4_xid()           # 32-bit transaction ID
DHCP.SecureRandom.generate_dhcpv6_transaction_id() # 24-bit transaction ID
DHCP.SecureRandom.generate_ia_id()                # 32-bit IAID
DHCP.SecureRandom.generate_bytes(16)              # Random DUID bytes
```

**Serialization/Parsing:**
```elixir
# Serialize: DHCP.to_iodata(message) |> IO.iodata_to_binary()
# DHCPv4 Parse: DHCPv4.Message.from_iodata(binary)
# DHCPv6 Parse: DHCPv6.Message.from_iodata(binary) -> {:ok, message} | {:error, reason}
```

### Alternatives Considered
- Building messages manually - Unnecessarily complex, Client modules handle this
- Third-party libraries - Would duplicate existing functionality

---

## LiveView Async Patterns

### Decision
Use `start_async/3` with `handle_async/3` for network operations. This is the standard Phoenix LiveView 1.0+ pattern for non-blocking tasks.

### Rationale
While the existing codebase uses telemetry subscriptions, timers, and PubSub for async patterns, these are appropriate for continuous monitoring scenarios. For one-off diagnostic queries with user-initiated requests and timeout handling, `start_async/3` is the right choice because:

1. **User-initiated**: User clicks "Send" and expects a response
2. **Bounded duration**: Query has a timeout
3. **Single result**: One response (or multiple for mDNS)
4. **Progress feedback**: Need to show loading state

### Key Findings

**Existing Patterns (Not Used for Diagnostics):**
- Telemetry subscriptions - For continuous monitoring events
- `:timer.send_interval` - For periodic polling
- Phoenix PubSub - For cross-LiveView events

**Recommended Pattern for Diagnostics:**
```elixir
def handle_event("send_query", params, socket) do
  socket = socket
    |> assign(:loading, true)
    |> start_async(:query, fn -> execute_query(params) end)
  {:noreply, socket}
end

def handle_async(:query, {:ok, result}, socket) do
  {:noreply, socket |> assign(:loading, false) |> assign(:result, result)}
end

def handle_async(:query, {:exit, reason}, socket) do
  {:noreply, socket |> assign(:loading, false) |> put_flash(:error, format_error(reason))}
end
```

### Error Handling Pattern
```elixir
defp execute_query(params) do
  start_time = System.monotonic_time(:millisecond)

  result = try do
    # Send query and receive response
    {:ok, response}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  latency = System.monotonic_time(:millisecond) - start_time
  {result, latency}
end
```

---

## Socket Usage for Diagnostics

### Decision
Use direct `:gen_udp` and `:gen_tcp` for diagnostic queries. This is a client-side tool, not a server.

### Rationale
The constitution prohibits direct socket usage in protocol server applications to ensure consistency via Abyss. However, this diagnostic tool is a client utility (like `dig` or `nslookup`), not a server implementation.

### Key Patterns

**DNS Query (UDP):**
```elixir
{:ok, socket} = :gen_udp.open(0, [:binary, active: false])
:gen_udp.send(socket, server_ip, port, query_binary)
result = :gen_udp.recv(socket, 0, timeout)
:gen_udp.close(socket)
```

**DNS Query (TCP):**
```elixir
{:ok, socket} = :gen_tcp.connect(server_ip, port, [:binary, active: false, packet: 2])
:gen_tcp.send(socket, query_binary)
result = :gen_tcp.recv(socket, 0, timeout)
:gen_tcp.close(socket)
```

**mDNS Query (Multicast):**
```elixir
{:ok, socket} = :gen_udp.open(0, [:binary, active: false,
  multicast_ttl: 255,
  multicast_loop: true
])
:gen_udp.send(socket, {224, 0, 0, 251}, 5353, query_binary)
# Collect responses until timeout
responses = collect_responses(socket, timeout, [])
:gen_udp.close(socket)
```

**DHCPv4 Query (Broadcast):**
```elixir
{:ok, socket} = :gen_udp.open(68, [:binary, active: false, broadcast: true])
:gen_udp.send(socket, {255, 255, 255, 255}, 67, message_binary)
result = :gen_udp.recv(socket, 0, timeout)
:gen_udp.close(socket)
```

**DHCPv6 Query (Multicast IPv6):**
```elixir
# Use :socket for IPv6 multicast
{:ok, socket} = :socket.open(:inet6, :dgram, :udp)
:socket.bind(socket, %{family: :inet6, port: 546, addr: :any})
:socket.sendto(socket, message_binary, %{
  family: :inet6,
  port: 547,
  addr: {0xff02, 0, 0, 0, 0, 0, 0x0001, 0x0002}
})
result = :socket.recvfrom(socket, 0, timeout)
:socket.close(socket)
```

---

## Hex Dump Formatting

### Decision
Implement xxd-style formatting with offset, hex bytes (16 per line), and ASCII sidebar.

### Rationale
xxd format is the standard for hex dumps and is immediately recognizable to network administrators.

### Implementation Pattern
```elixir
def format_hex(binary) do
  binary
  |> :binary.bin_to_list()
  |> Enum.chunk_every(16, 16, Stream.repeatedly(fn -> nil end))
  |> Enum.with_index()
  |> Enum.map(fn {bytes, index} ->
    offset = String.pad_leading(Integer.to_string(index * 16, 16), 8, "0")
    hex = format_hex_bytes(bytes)
    ascii = format_ascii(bytes)
    "#{offset}: #{hex}  #{ascii}"
  end)
  |> Enum.join("\n")
end

# Output example:
# 00000000: 00 01 01 00 00 01 00 00 00 00 00 00 07 65 78 61  .............exa
# 00000010: 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01           mple.com.....
```

---

## Clipboard API

### Decision
Use `navigator.clipboard.writeText()` via JavaScript hook for copy functionality.

### Rationale
This is the modern browser API for clipboard operations. Phoenix LiveView hooks provide the integration point.

### Implementation Pattern
```javascript
// In app.js
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const content = this.el.dataset.content;
      navigator.clipboard.writeText(content).then(() => {
        this.pushEvent("copied", {});
      });
    });
  }
}
```

```elixir
# In LiveView
<button phx-hook="CopyToClipboard" data-content={@content}>
  Copy
</button>

def handle_event("copied", _params, socket) do
  {:noreply, put_flash(socket, :info, "Copied to clipboard")}
end
```

---

## Summary of Decisions

| Topic | Decision | Rationale |
|-------|----------|-----------|
| DNS Library | ex_dns `DNS.Message` | Already integrated, production-ready |
| DHCP Library | ex_dhcp `DHCPv4/v6.Client` | Convenient client utilities |
| Async Pattern | `start_async/3` | Appropriate for user-initiated queries |
| Socket Usage | Direct `:gen_udp`/`:gen_tcp` | Client tool, not server |
| Hex Format | xxd-style | Industry standard, familiar |
| Clipboard | JS hook with navigator API | Modern browser API |
