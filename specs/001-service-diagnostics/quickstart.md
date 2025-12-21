# Quickstart: Service Diagnostics Page

**Date**: 2025-12-19
**Branch**: `001-service-diagnostics`

## Overview

This document provides a quick reference for implementing the Service Diagnostics page.

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                     DiagnosticsLive                         │
│                    (Main LiveView)                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐           │
│  │DNS Tab  │ │mDNS Tab │ │DHCPv4   │ │DHCPv6   │           │
│  │Component│ │Component│ │Tab Comp │ │Tab Comp │           │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘           │
│       │           │           │           │                 │
│  ┌────▼────────────▼───────────▼───────────▼────┐          │
│  │              Shared Components                │          │
│  │  • QueryForm  • ResultDisplay  • QueryHistory│          │
│  └──────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Protocol Clients                         │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐   │
│  │ DnsClient │ │MdnsClient │ │Dhcpv4Client│ │Dhcpv6Client│  │
│  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘   │
│        │             │             │             │          │
│  ┌─────▼─────────────▼─────────────▼─────────────▼─────┐   │
│  │              Protocol Libraries                      │   │
│  │        ex_dns (DNS.Message, DNS.to_iodata)          │   │
│  │     ex_dhcp (DHCPv4.Client, DHCPv6.Client)          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Key Files to Create

### LiveView Files

| File | Purpose |
|------|---------|
| `live/diagnostics_live/diagnostics_live.ex` | Main LiveView, tab navigation |
| `live/diagnostics_live/dns_tab.ex` | DNS query form and results |
| `live/diagnostics_live/mdns_tab.ex` | mDNS query form and results |
| `live/diagnostics_live/dhcpv4_tab.ex` | DHCPv4 query form and results |
| `live/diagnostics_live/dhcpv6_tab.ex` | DHCPv6 query form and results |

### Component Files

| File | Purpose |
|------|---------|
| `live/diagnostics_live/components/query_form.ex` | Reusable form component |
| `live/diagnostics_live/components/result_display.ex` | Struct/Raw view toggle |
| `live/diagnostics_live/components/hex_dump.ex` | xxd-style formatting |
| `live/diagnostics_live/components/query_history.ex` | Collapsible history |

### Client Files

| File | Purpose |
|------|---------|
| `diagnostics/dns_client.ex` | DNS query execution |
| `diagnostics/mdns_client.ex` | mDNS multicast queries |
| `diagnostics/dhcpv4_client.ex` | DHCPv4 broadcast queries |
| `diagnostics/dhcpv6_client.ex` | DHCPv6 multicast queries |
| `diagnostics/hex_formatter.ex` | Binary to hex formatting |
| `diagnostics/query_result.ex` | QueryResult struct |

### Test Files

| File | Purpose |
|------|---------|
| `test/live/diagnostics_live_test.exs` | LiveView integration tests |
| `test/diagnostics/*_test.exs` | Unit tests for clients |

## Router Setup

```elixir
# In router.ex, add to live session:
live "/diagnostics", DiagnosticsLive, :index
```

## Quick Implementation Patterns

### 1. Main LiveView Mount

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:page_title, "Service Diagnostics")
   |> assign(:active_tab, :dns)
   |> assign(:display_mode, :struct)
   |> assign(:tabs, init_tabs())}
end

defp init_tabs do
  %{
    dns: %{form: default_dns_form(), loading: false, current_result: nil, history: []},
    mdns: %{form: default_mdns_form(), loading: false, current_result: nil, history: []},
    dhcpv4: %{form: default_dhcpv4_form(), loading: false, current_result: nil, history: []},
    dhcpv6: %{form: default_dhcpv6_form(), loading: false, current_result: nil, history: []}
  }
end
```

### 2. Async Query Pattern

```elixir
def handle_event("send_query", %{"dns_query" => params}, socket) do
  socket =
    socket
    |> update_tab(:dns, &Map.put(&1, :loading, true))
    |> start_async(:dns_query, fn -> DnsClient.query(params) end)

  {:noreply, socket}
end

def handle_async(:dns_query, {:ok, {:ok, result}}, socket) do
  socket =
    socket
    |> update_tab(:dns, fn tab ->
      %{tab |
        loading: false,
        current_result: result,
        history: [result | tab.history] |> Enum.take(10)
      }
    end)

  {:noreply, socket}
end
```

### 3. Tab Component Template

```heex
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">DNS Query</h2>

    <.form for={@form} phx-change="validate" phx-submit="send_query">
      <.input field={@form[:query_name]} label="Domain Name" />
      <.input field={@form[:record_type]} type="select" label="Record Type"
              options={[A: "a", AAAA: "aaaa", MX: "mx", TXT: "txt"]} />
      <!-- More fields -->
      <.button type="submit" class="btn btn-primary" disabled={@loading}>
        <%= if @loading, do: "Sending...", else: "Send Query" %>
      </.button>
    </.form>

    <%= if @result do %>
      <.result_display result={@result} mode={@display_mode} />
    <% end %>

    <.query_history history={@history} on_select="select_history" />
  </div>
</div>
```

### 4. DNS Client Implementation

```elixir
def query(params) do
  start_time = System.monotonic_time(:millisecond)
  message = build_message(params)
  binary = DNS.to_iodata(message) |> IO.iodata_to_binary()

  result =
    case params.protocol do
      :udp -> query_udp(params, binary)
      :tcp -> query_tcp(params, binary)
    end

  latency = System.monotonic_time(:millisecond) - start_time

  case result do
    {:ok, response_binary} ->
      response = DNS.Message.from_iodata(response_binary)
      {:ok, build_result(params, message, binary, response, response_binary, latency)}

    {:error, reason} ->
      {:error, reason}
  end
end
```

## Testing Strategy

### Unit Tests (Client Modules)

```elixir
describe "DnsClient.query/1" do
  test "builds correct DNS message" do
    # Test message structure
  end

  test "handles timeout gracefully" do
    # Test with unreachable server
  end

  test "parses response correctly" do
    # Test with mock response
  end
end
```

### Integration Tests (LiveView)

```elixir
describe "DiagnosticsLive" do
  test "renders all tabs" do
    {:ok, view, _html} = live(conn, "/diagnostics")
    assert has_element?(view, "[data-tab=dns]")
    assert has_element?(view, "[data-tab=mdns]")
    assert has_element?(view, "[data-tab=dhcpv4]")
    assert has_element?(view, "[data-tab=dhcpv6]")
  end

  test "switches tabs correctly" do
    {:ok, view, _html} = live(conn, "/diagnostics")
    view |> element("[data-tab=mdns]") |> render_click()
    assert has_element?(view, ".mdns-form")
  end
end
```

## DaisyUI Components Used

- `tabs tabs-boxed` - Tab navigation
- `card` - Content containers
- `form-control` - Form inputs
- `btn btn-primary` - Action buttons
- `badge` - Status indicators
- `collapse` - History panel
- `alert` - Error/warning messages
- `loading` - Loading spinner
- `tooltip` - Help text

## Common Gotchas

1. **DHCP Ports**: Ports 67/68 (DHCPv4) and 546/547 (DHCPv6) require root. Always show warning.

2. **mDNS Multicast**: Must set `multicast_ttl: 255` and `multicast_loop: true` for local testing.

3. **IPv6 Sockets**: Use `:socket` module instead of `:gen_udp` for IPv6 multicast.

4. **DNS TCP**: DNS over TCP uses 2-byte length prefix (`packet: 2` option).

5. **Binary Display**: Ensure hex dump handles empty binaries and very long responses.

6. **Form Validation**: Validate on every change to provide immediate feedback.

7. **History Limit**: Remember to `Enum.take(10)` after prepending to history.
