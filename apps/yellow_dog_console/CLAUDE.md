# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

YellowDogConsole is the Phoenix LiveView web console for managing and monitoring YellowDog network services (DNS, mDNS, DHCPv4, DHCPv6). It uses the Duskmoon design system (`@duskmoon-dev/core` + `phoenix_duskmoon`) for UI components and Bun for JavaScript bundling.

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

All views auto-import `PhoenixDuskmoon.Component` (dm_* components) and `YellowDog.Console.CoreComponents`.

### Directory Structure
```
lib/yellow_dog/console/
├── application.ex            # Application supervisor
├── endpoint.ex              # Phoenix endpoint
├── router.ex                # Routes definition
├── components/
│   ├── core_components.ex   # Project component library (stat, badge, card, modal, table, etc.)
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

### UI Design System

**Stack:**
- `@duskmoon-dev/core` — CSS component library (TailwindCSS v4 plugin, MD3 color system)
- `phoenix_duskmoon` — Phoenix HEEX components (`dm_*` prefix)
- `@duskmoon-dev/elements` — Custom elements (`<el-dm-*>`)

**Themes:** `sunshine` (light) / `moonlight` (dark), set via `data-theme` attribute on `<body>`.

**Icons:** Use `<.dm_mdi name="icon-name" class="w-N h-N" />` (Material Design Icons). Never use inline SVGs.

**Color tokens:**
- Surfaces: `bg-surface`, `bg-surface-container`, `bg-surface-container-high`
- Text: `text-on-surface`, `text-on-surface-variant`
- Borders: `border-outline`, `border-outline-variant`
- Semantic: `text-primary`, `text-secondary`, `text-success`, `text-error`, `text-warning`, `text-info`

**Components (from phoenix_duskmoon):**
```heex
<.dm_btn variant="primary" size="md">Save</.dm_btn>
<.dm_card variant="bordered"><:title>Title</:title>Content</.dm_card>
<.dm_mdi name="home" class="w-6 h-6" />
<.dm_navbar><:start>...</:start><:end>...</:end></.dm_navbar>
<.dm_theme_switcher id="theme-toggle" />
<.dm_modal id="my-modal"><:trigger>...</:trigger><:body>...</:body></.dm_modal>
<.dm_tab id="tabs" active_tab_index={0}><:tab name="a">A</:tab><:tab_content name="a">...</:tab_content></.dm_tab>
```

**Components (from CoreComponents):**
```heex
<.stat title="..." value="..." desc="..." />
<.badge color="success" size="sm">Active</.badge>
<.card title="..."><:actions>...</:actions></.card>
<.modal id="..." title="..." show={@show}>...</.modal>
<.table id="..." rows={@items}><:col :let={item} label="Name">{item.name}</:col></.table>
<.progress value={50} color="success" />
<.status_indicator status="running" label="..." pulse />
```

Modal helpers: `show_modal(id)`, `hide_modal(id)` (use `dialog-backdrop-show` class).

### Layout System
Phoenix 1.8 function component layouts in `layouts.ex`:
- `root.html.heex` - HTML skeleton (in `layouts/` directory)
- `app/1` - Main app layout with drawer navigation
- `navbar/1` - Top navigation bar with theme switcher
- `sidebar/1` - Collapsible sidebar using `nested-menu` CSS classes
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
- Duskmoon hooks: `ThemeSwitcher`, `WebComponentHook`, `FormElementHook`, `PageHeader`, `Spotlight` (from `phoenix_duskmoon/hooks`)
- Custom hooks: `CopyToClipboard`, `CsvDownload`, `LogAutoScroll`

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
- Entry point: `assets/js/app.js`
- CSS entry: `assets/css/app.css`
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
- `phoenix_duskmoon` ~> 9.0
- `tailwind` ~> 0.3, `bun` ~> 1.3 (dev only)
- `@duskmoon-dev/core`, `@duskmoon-dev/elements` (npm)
- In-umbrella: `yellow_dog`, `yellow_dog_mdns`, `yellow_dog_dhcpv4`, `yellow_dog_dhcpv6`, `yellow_dog_dns`
