# Research: Real-time Logs Page

**Date**: 2025-12-24
**Feature**: 001-realtime-logs-page

## Research Summary

All technical unknowns have been resolved through codebase exploration.

---

## 1. Telemetry Log Event Structure

**Decision**: Subscribe to `[:yellow_dog, :log, :debug|:info|:warning|:error]` events

**Rationale**: The YellowDog.Telemetry module already emits structured log events at these event names. Each event includes:
- `message` - The log message (string)
- `app` - Source application atom (`:yellow_dog_dns`, `:yellow_dog_dhcpv4`, etc.)
- `module` - Calling module atom
- `function` - Function name with arity (e.g., `"handle_data/2"`)
- `line` - Source line number
- Measurements include `monotonic_time`

**Alternatives Considered**:
- Direct Logger backend: Rejected - violates constitution (no direct Logger usage)
- Custom telemetry events: Rejected - existing events already provide all needed data

**Source**: `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry.ex` lines 539-569

---

## 2. LiveView Telemetry Subscription Pattern

**Decision**: Use a dedicated `LogBroadcaster` GenServer that attaches to telemetry events and broadcasts via Phoenix.PubSub to the `"logs:stream"` topic

**Rationale**: This pattern is already established in the codebase:
- mDNS uses `"mdns:services"` and `"mdns:monitor"` topics
- DHCP uses telemetry attach pattern with `send(pid, ...)` forwarding
- A central broadcaster avoids each LiveView attaching its own handler (cleaner, single subscription point)

**Implementation Pattern**:
```elixir
# LogBroadcaster attaches to all log events once at startup
:telemetry.attach_many(
  "log-broadcaster",
  [
    [:yellow_dog, :log, :debug],
    [:yellow_dog, :log, :info],
    [:yellow_dog, :log, :warning],
    [:yellow_dog, :log, :error]
  ],
  &handle_log_event/4,
  %{}
)

# Handler broadcasts to PubSub
defp handle_log_event(event, measurements, metadata, _config) do
  level = List.last(event)
  Phoenix.PubSub.broadcast(
    YellowDog.Console.PubSub,
    "logs:stream",
    {:log_event, level, measurements, metadata}
  )
end
```

**LiveView subscribes in mount**:
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "logs:stream")
  end
  {:ok, assign(socket, logs: [], paused: false, ...)}
end

def handle_info({:log_event, level, measurements, metadata}, socket) do
  if not socket.assigns.paused do
    log_entry = build_log_entry(level, measurements, metadata)
    {:noreply, add_log_entry(socket, log_entry)}
  else
    {:noreply, buffer_log_entry(socket, log_entry)}
  end
end
```

**Alternatives Considered**:
- Direct telemetry attach per LiveView: Rejected - requires cleanup in terminate/2, more complex
- GenStage for backpressure: Rejected - overkill for log display; simple buffer with FIFO eviction sufficient

---

## 3. Log Buffer Management

**Decision**: Keep logs in a list with max 1000 entries, FIFO eviction (drop oldest when full)

**Rationale**:
- Simple implementation using `Enum.take/2`
- 1000 entries is sufficient for real-time viewing
- Memory overhead is minimal (~1MB for 1000 entries with metadata)

**Implementation**:
```elixir
defp add_log_entry(socket, entry) do
  logs = [entry | socket.assigns.logs]
  |> Enum.take(1000)

  assign(socket, logs: logs)
end
```

**Alternatives Considered**:
- ETS table: Rejected - unnecessary complexity for single-page transient data
- Circular buffer library: Rejected - simple list sufficient

---

## 4. Auto-scroll Behavior

**Decision**: Use JavaScript hook with `phx-hook="LogAutoScroll"` to control scroll behavior

**Rationale**:
- LiveView can't directly control scroll position
- JS hook can detect if user has scrolled up and disable auto-scroll
- Re-enable auto-scroll when user scrolls to bottom

**Implementation**:
```javascript
// assets/js/app.js
Hooks.LogAutoScroll = {
  mounted() {
    this.autoScroll = true
    this.el.addEventListener('scroll', () => {
      const atBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 50
      this.autoScroll = atBottom
    })
  },
  updated() {
    if (this.autoScroll) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}
```

---

## 5. Module Filter Mapping

**Decision**: Map display names to telemetry app atoms

| Display Name | App Atom |
|-------------|----------|
| DNS | `:yellow_dog_dns` |
| DHCPv4 | `:yellow_dog_dhcpv4` |
| DHCPv6 | `:yellow_dog_dhcpv6` |
| mDNS | `:yellow_dog_mdns` |
| Console | `:yellow_dog_console` |
| Core | `:yellow_dog` |

**Filtering Logic**: Client-side filtering in the LiveView `handle_info` - if the incoming log's `app` is not in `selected_modules`, skip adding to the visible list.

---

## 6. Log Level Priority

**Decision**: Use threshold-based filtering (selecting "Warning" shows Warning + Error)

**Level Priority** (from YellowDog.Telemetry):
- `:debug` = 0
- `:info` = 1
- `:warning` = 2
- `:error` = 3

**Filtering Logic**:
```elixir
@level_priority %{debug: 0, info: 1, warning: 2, error: 3}

defp should_display?(log_entry, min_level) do
  Map.get(@level_priority, log_entry.level, 0) >= Map.get(@level_priority, min_level, 0)
end
```

---

## 7. Connection Status Indicator

**Decision**: Use LiveView's built-in connection status via `phx-disconnected` and `phx-connected` attributes

**Rationale**: Phoenix LiveView already handles WebSocket reconnection. The existing layouts.ex already has a connection error flash. We can add a status indicator badge that responds to these events.

**Implementation**: Badge in the logs header that shows "Connected" (green) or "Reconnecting..." (amber) using the existing DaisyUI `.badge` component.

---

## 8. Rate Limiting Display

**Decision**: Apply rate limiting at the LiveView level by batching updates

**Rationale**:
- High-frequency log events could overwhelm the browser
- Batch updates every 100ms using `Process.send_after`
- Maximum 100 entries per batch (configurable)

**Implementation**:
```elixir
def handle_info(:flush_log_buffer, socket) do
  logs = socket.assigns.pending_logs ++ socket.assigns.logs
  |> Enum.take(1000)

  schedule_flush()
  {:noreply, assign(socket, logs: logs, pending_logs: [])}
end

defp schedule_flush do
  Process.send_after(self(), :flush_log_buffer, 100)
end
```

---

## 9. Existing UI Patterns

**Decision**: Follow existing console patterns from diagnostics_live.ex and mdns_live/*.ex

**Key Patterns Identified**:
- Tab-like controls using DaisyUI `.btn-group` or `.join`
- Filter state in assigns with checkbox inputs
- Stats display using `<.stat>` component
- Tables for log entries (or custom log display using monospace font)
- Modal forms not needed for this feature

**Log Entry Display**: Use a monospace `<pre>` or `<code>` block inside a scrollable container with DaisyUI styling.

---

## 10. Sidebar Navigation

**Decision**: Navigation link already exists at `/logs` in sidebar (layouts.ex lines 358-376)

**Rationale**: The sidebar already includes a "Logs" link pointing to `/logs`. We only need to:
1. Add the route in router.ex
2. Implement the LogsLive module

---

## Dependencies Confirmed

- **YellowDog.Telemetry**: Log events already emitted ✅
- **Phoenix.PubSub**: Available as `YellowDog.Console.PubSub` ✅
- **DaisyUI components**: Available via CoreComponents ✅
- **JavaScript hooks**: Existing pattern in app.js for ThemeToggle ✅

---

## Open Questions Resolved

| Question | Resolution |
|----------|------------|
| How are log events emitted? | Via `YellowDog.Telemetry.info/2`, etc. → `[:yellow_dog, :log, level]` |
| How to subscribe from LiveView? | PubSub subscription in mount/3 when connected |
| Where to put LogBroadcaster? | `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/log_broadcaster.ex` |
| How to handle metadata display? | Hover/expand pattern (from spec clarification) |
| Route already configured? | Route NOT in router.ex yet, but sidebar link exists |
