# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

YellowDogConsole is the Phoenix LiveView web console for managing and monitoring YellowDog network services (DNS, mDNS, DHCPv4, DHCPv6). It uses DaisyUI 5.0 for UI components and Bun for JavaScript bundling.

## Common Commands

```bash
# Start the Phoenix server (development mode)
mix phx.server
# Or with IEx for debugging
iex -S mix phx.server

# Visit http://localhost:4270

# Run tests
mix test

# Run a specific test file
mix test test/yellow_dog/console/live/settings_live_test.exs

# Run tests matching a pattern
mix test --only capture_log

# Build assets (Tailwind + Bun)
mix assets.build

# Build production assets
mix assets.deploy

# Setup dependencies and assets
mix setup

# Format code
mix format

# Lint with Credo
mix credo --strict
```

## Architecture

### Module Pattern
Use `YellowDog.Console` for the entrypoint with these uses:
- `use YellowDog.Console, :controller` - Controllers
- `use YellowDog.Console, :live_view` - LiveViews
- `use YellowDog.Console, :live_component` - LiveComponents
- `use YellowDog.Console, :html` - Function components

### Directory Structure
```
lib/yellow_dog/console/
├── application.ex            # Application supervisor
├── endpoint.ex              # Phoenix endpoint
├── router.ex                # Routes definition
├── components/
│   ├── core_components.ex   # DaisyUI component library
│   └── layouts.ex           # Layout components (app, navbar, sidebar)
├── live/
│   ├── dashboard_live.ex    # Service overview
│   ├── dns_live/           # DNS management pages
│   ├── dhcpv4_live/        # DHCPv4 management pages
│   ├── dhcpv6_live/        # DHCPv6 management pages
│   ├── mdns_live/          # mDNS management pages
│   ├── settings_live.ex    # Configuration settings
│   ├── diagnostics_live/   # Service diagnostics
│   ├── logs_live.ex        # Real-time logs
│   └── process_map_live.ex # Process visualization
├── diagnostics/            # Protocol-specific diagnostic clients
├── settings/               # Configuration data structures
├── services/               # Service introspection
└── plugs/                  # Authentication and rate limiting
```

### DaisyUI Components (CoreComponents)
Available components in all views via auto-import:
```elixir
<.stat title="..." value="..." desc="..." />
<.badge color="success|error|warning|info" />
<.card title="..."><:actions>...</:actions></.card>
<.modal id="..." title="..." show={@show_modal}>...</.modal>
<.table id="..." rows={@items} zebra hover>
  <:col :let={item} label="Name">{item.name}</:col>
  <:action :let={item}>...</:action>
</.table>
<.progress value={50} color="success" />
<.radial_progress value={75} size="lg" />
<.status_indicator status="running|stopped|warning" label="..." pulse />
<.toast id="..." type="success|error|warning|info">Message</.toast>
<.loading size="sm|md|lg" />
```

Modal helpers: `show_modal(id)`, `hide_modal(id)`

### Layout System
Phoenix 1.8 function component layouts in `layouts.ex`:
- `root.html.heex` - HTML skeleton (in `layouts/` directory)
- `app/1` - Main app layout with drawer navigation
- `navbar/1` - Top navigation bar with theme toggle
- `sidebar/1` - Collapsible sidebar menu
- `flash_group/1` - Flash message display

### LiveView Patterns
1. **Page wrapper**: Always wrap LiveView content in `<Layouts.app flash={@flash}>`:
   ```heex
   def render(assigns) do
     ~H"""
     <Layouts.app flash={@flash}>
       <!-- Page content here -->
     </Layouts.app>
     """
   end
   ```
2. **Tab navigation with URL routes**: Each tab is a separate route
3. **Form validation**: Use Ecto changesets with `YellowDog.Console.Validators`
4. **Real-time updates**: Subscribe to PubSub topics in `mount/3` when `connected?(socket)`
5. **Modal forms**: Control visibility with socket assigns (e.g., `@show_form`)
6. **Configuration persistence**: Use `ConfigManager` for TOML config file operations

### JavaScript Hooks
Located in `assets/js/app.js`:
- `ThemeToggle` - Dark/light mode with localStorage persistence
- `CopyToClipboard` - Copy content to clipboard
- `LogAutoScroll` - Auto-scroll log viewer

## Testing Patterns

### LiveView Tests
```elixir
use YellowDog.Console.ConnCase, async: false
import Phoenix.LiveViewTest

test "mounts successfully", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/settings")
  assert html =~ "Service Settings"
  assert has_element?(view, "a[href='/settings/dns']")
end

test "validates form", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/settings")
  html = view
    |> form("form", service_configuration: %{listen: "invalid"})
    |> render_change()
  assert html =~ "must be a valid IP address"
end
```

### Test Setup with Temporary Config
```elixir
setup do
  config_path = Path.join(System.tmp_dir!(), "test_config_#{:rand.uniform(100_000)}.toml")
  File.write!(config_path, default_config)
  Application.put_env(:yellow_dog_console, :config_path, config_path)
  on_exit(fn -> File.rm_rf(config_path) end)
  %{config_path: config_path}
end
```

## Asset Building

Uses Bun for JavaScript bundling (not npm):
- Phoenix deps symlinked from `deps/` to `node_modules/`
- Entry point: `assets/js/app.js`
- Output: `priv/static/assets/`

```bash
# Development build with sourcemaps
bun run build
# Production build (minified)
bun run build:prod
# Watch mode
bun run watch
```

## Key Dependencies

- `phoenix` ~> 1.8.1, `phoenix_live_view` ~> 1.0
- `bandit` ~> 1.5 (HTTP server)
- `tailwind` ~> 0.3, `bun` ~> 1.3 (dev only)
- `heroicons` ~> 0.5.6
- In-umbrella: `yellow_dog`, `yellow_dog_mdns`, `yellow_dog_dhcpv4`, `yellow_dog_dhcpv6`, `yellow_dog_dns`
