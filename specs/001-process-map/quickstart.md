# Quickstart: Process Map Development

**Feature**: 001-process-map
**Date**: 2024-12-28

## Prerequisites

- Elixir 1.18+ with OTP 27+
- Node.js (for Bun asset bundler)
- Development environment activated via `direnv allow` or `devenv shell`

## Getting Started

### 1. Switch to Feature Branch

```bash
cd /home/gao/Workspace/gsmlg-dev/yellow-dog
git checkout 001-process-map
```

### 2. Install Dependencies

```bash
mix deps.get
```

### 3. Start Development Server

```bash
# Start the Phoenix console server
cd apps/yellow_dog_console
iex -S mix phx.server
```

Then visit: http://localhost:4000/process-map

### 4. Run Tests

```bash
# Run all console tests
mix test apps/yellow_dog_console

# Run specific tests
mix test apps/yellow_dog_console/test/yellow_dog/console/services/process_inspector_test.exs
mix test apps/yellow_dog_console/test/yellow_dog/console/live/process_map_live_test.exs
```

## Development Workflow

### File Locations

| Component | Path |
|-----------|------|
| LiveView page | `apps/yellow_dog_console/lib/yellow_dog/console/live/process_map_live.ex` |
| Process inspector | `apps/yellow_dog_console/lib/yellow_dog/console/services/process_inspector.ex` |
| Router | `apps/yellow_dog_console/lib/yellow_dog/console/router.ex` |
| Sidebar | `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex` |
| CSS (if needed) | `apps/yellow_dog_console/assets/css/app.css` |

### Implementation Order

1. **ProcessInspector module** - Create service for tree introspection
2. **Router** - Add `/process-map` route
3. **Sidebar** - Add "Process Map" menu item under System
4. **ProcessMapLive** - Create LiveView page
5. **Tests** - Unit and LiveView tests
6. **Styling** - Refine tree visualization CSS

### Testing in IEx

```elixir
# Test process inspector
alias YellowDog.Console.ProcessInspector

# Get all trees
ProcessInspector.get_trees()

# Get specific app tree
ProcessInspector.get_app_tree(:yellow_dog_dns)

# Get process status
ProcessInspector.get_process_status(self())
```

### Useful IEx Commands

```elixir
# List YellowDog applications
Application.started_applications() |> Enum.filter(fn {app, _, _} ->
  to_string(app) |> String.starts_with?("yellow_dog")
end)

# Get supervisor children directly
:supervisor.which_children(YellowDog.Dns.Supervisor)

# Get process info
:erlang.process_info(self(), [:registered_name, :current_function, :memory])
```

## Code Style Guidelines

### Module Template

```elixir
defmodule YellowDog.Console.ProcessMapLive do
  @moduledoc """
  LiveView page for viewing Erlang process supervision trees.

  Displays an interactive tree diagram of YellowDog application
  processes with click-to-view status functionality.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ProcessInspector

  @refresh_interval 5_000  # 5 seconds

  @impl true
  def mount(_params, _session, socket) do
    # Implementation
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <!-- Template -->
    </Layouts.app>
    """
  end
end
```

### Telemetry Events (Constitution Compliance)

Use telemetry for logging, not direct Logger:

```elixir
# Instead of: Logger.info("Process tree refreshed")
:telemetry.execute(
  [:yellow_dog, :console, :process_map, :refresh],
  %{count: 1, process_count: length(processes)},
  %{app: :yellow_dog_console}
)
```

## Verification Checklist

Before submitting:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix format --check-formatted` passes
- [ ] `mix test apps/yellow_dog_console` passes
- [ ] `mix credo --strict` passes (no new issues)
- [ ] Page loads in under 2 seconds
- [ ] Click response under 1 second
- [ ] Tree updates every 5 seconds
- [ ] Expand/collapse works correctly
- [ ] Status panel shows all required info
- [ ] Works with 50+ processes displayed
