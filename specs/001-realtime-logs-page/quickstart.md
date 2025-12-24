# Quickstart: Real-time Logs Page

**Date**: 2025-12-24
**Feature**: 001-realtime-logs-page

## Prerequisites

- Elixir 1.18+ with OTP 27+
- Development environment activated (`direnv allow` or `devenv shell`)
- YellowDog console running (`iex -S mix phx.server` from `apps/yellow_dog_console`)

## Quick Implementation Guide

### Step 1: Add LogBroadcaster GenServer

Create `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/log_broadcaster.ex`:

```elixir
defmodule YellowDog.Telemetry.LogBroadcaster do
  @moduledoc """
  Broadcasts telemetry log events to connected LiveView processes via PubSub.
  """
  use GenServer

  @pubsub YellowDog.Console.PubSub
  @topic "logs:stream"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :telemetry.attach_many(
      "log-broadcaster",
      [
        [:yellow_dog, :log, :debug],
        [:yellow_dog, :log, :info],
        [:yellow_dog, :log, :warning],
        [:yellow_dog, :log, :error]
      ],
      &__MODULE__.handle_log_event/4,
      %{}
    )
    {:ok, %{}}
  end

  def handle_log_event(event, measurements, metadata, _config) do
    level = List.last(event)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:log_event, level, measurements, metadata})
  end
end
```

### Step 2: Add Route

In `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`, add:

```elixir
live "/logs", LogsLive
```

### Step 3: Create LogsLive Module

Create `apps/yellow_dog_console/lib/yellow_dog/console/live/logs_live.ex`:

```elixir
defmodule YellowDog.Console.LogsLive do
  use YellowDog.Console, :live_view

  @max_logs 1000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "logs:stream")
    end

    {:ok,
     assign(socket,
       page_title: "Logs",
       logs: [],
       paused: false,
       min_level: :debug,
       selected_apps: MapSet.new()
     )}
  end

  def handle_info({:log_event, level, measurements, metadata}, socket) do
    if should_display?(socket.assigns, level, metadata.app) and not socket.assigns.paused do
      entry = build_entry(level, measurements, metadata)
      logs = Enum.take([entry | socket.assigns.logs], @max_logs)
      {:noreply, assign(socket, logs: logs)}
    else
      {:noreply, socket}
    end
  end

  defp should_display?(%{min_level: min, selected_apps: apps}, level, app) do
    level_ok = level_priority(level) >= level_priority(min)
    app_ok = MapSet.size(apps) == 0 or MapSet.member?(apps, app)
    level_ok and app_ok
  end

  defp level_priority(:debug), do: 0
  defp level_priority(:info), do: 1
  defp level_priority(:warning), do: 2
  defp level_priority(:error), do: 3

  defp build_entry(level, measurements, metadata) do
    %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      level: level,
      app: metadata.app,
      module: metadata.module,
      message: metadata.message,
      metadata: Map.drop(metadata, [:app, :module, :message, :function, :line])
    }
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Real-time Logs</h1>
        <div class="join">
          <button phx-click="toggle_pause" class={"btn join-item " <> if(@paused, do: "btn-warning", else: "btn-ghost")}>
            <%= if @paused, do: "Resume", else: "Pause" %>
          </button>
          <button phx-click="clear" class="btn btn-ghost join-item">Clear</button>
        </div>
      </div>

      <div class="bg-base-200 rounded-lg p-4 font-mono text-sm h-[600px] overflow-y-auto" phx-hook="LogAutoScroll" id="log-container">
        <%= for log <- Enum.reverse(@logs) do %>
          <div class={"py-1 border-b border-base-300 " <> level_color(log.level)}>
            <span class="text-base-content/50"><%= format_time(log.timestamp) %></span>
            <span class={"badge badge-sm " <> level_badge(log.level)}><%= log.level %></span>
            <span class="badge badge-sm badge-outline"><%= app_name(log.app) %></span>
            <span><%= log.message %></span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("toggle_pause", _, socket) do
    {:noreply, assign(socket, paused: not socket.assigns.paused)}
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, logs: [])}
  end

  defp level_color(:debug), do: "text-base-content/60"
  defp level_color(:info), do: "text-info"
  defp level_color(:warning), do: "text-warning"
  defp level_color(:error), do: "text-error"

  defp level_badge(:debug), do: "badge-ghost"
  defp level_badge(:info), do: "badge-info"
  defp level_badge(:warning), do: "badge-warning"
  defp level_badge(:error), do: "badge-error"

  defp app_name(:yellow_dog_dns), do: "DNS"
  defp app_name(:yellow_dog_dhcpv4), do: "DHCPv4"
  defp app_name(:yellow_dog_dhcpv6), do: "DHCPv6"
  defp app_name(:yellow_dog_mdns), do: "mDNS"
  defp app_name(:yellow_dog_console), do: "Console"
  defp app_name(:yellow_dog), do: "Core"
  defp app_name(other), do: to_string(other)

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)
end
```

### Step 4: Add JavaScript Hook

In `apps/yellow_dog_console/assets/js/app.js`, add:

```javascript
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

### Step 5: Start LogBroadcaster

Add to the YellowDog.Console.Application supervisor children:

```elixir
{YellowDog.Telemetry.LogBroadcaster, []}
```

## Testing

```bash
# Run console with logging
cd apps/yellow_dog_console
iex -S mix phx.server

# Visit http://localhost:4000/logs

# Generate test logs from iex
YellowDog.Telemetry.info("Test message", %{})
YellowDog.Telemetry.error("Error test", %{code: 500})
```

## Key Files

| File | Purpose |
|------|---------|
| `apps/yellow_dog_telemetry/lib/yellow_dog/telemetry/log_broadcaster.ex` | Broadcasts telemetry events |
| `apps/yellow_dog_console/lib/yellow_dog/console/live/logs_live.ex` | LiveView page |
| `apps/yellow_dog_console/lib/yellow_dog/console/router.ex` | Route definition |
| `apps/yellow_dog_console/assets/js/app.js` | Auto-scroll hook |

## Common Issues

1. **No logs appearing**: Ensure LogBroadcaster is started in supervisor
2. **PubSub not found**: Verify `YellowDog.Console.PubSub` is started in Console.Application
3. **Auto-scroll not working**: Check that `phx-hook="LogAutoScroll"` is on the container element
