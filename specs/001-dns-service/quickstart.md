# Quickstart: DNS Service Implementation Fix and Dashboard Service Controls

**Branch**: `001-dns-service` | **Date**: 2025-12-10

## Prerequisites

- Elixir 1.18+ with OTP 27+
- Development environment activated (`direnv allow` or `devenv shell`)
- Project dependencies installed (`mix deps.get`)

## Quick Verification

### 1. Check Current DNS Service State

```bash
# Start IEx session
iex -S mix

# Check if DNS is enabled
iex> YellowDog.Config.service_enabled?(:dns)
true  # or false

# Get DNS status
iex> YellowDog.get_service_status(:dns)
%{enabled: true, running: false, ...}
```

### 2. Verify DNS Supervisor Issue

```bash
# Check DNS supervisor module
iex> Code.ensure_loaded?(YellowDog.Dns.Supervisor)
true

# Try to start DNS (will likely fail with current code)
iex> YellowDog.Dns.Supervisor.start_link([])
:ignore  # <-- This is the bug! Should return {:ok, pid}
```

### 3. Compare with Working mDNS

```bash
# mDNS supervisor doesn't return :ignore
iex> YellowDog.Mdns.Supervisor.start_link([])
{:ok, #PID<0.xxx.0>}  # Correct behavior
```

## Development Workflow

### Step 1: Fix DNS Supervisor

Edit `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex`:

```elixir
# BEFORE (broken):
def start_link(opts) do
  unless apply(YellowDog.Config, :service_enabled?, [:dns]) do
    Telemetry.info("DNS service is disabled, skipping startup")
    :ignore
  else
    # ... start supervisor
  end
end

# AFTER (fixed):
def start_link(opts) do
  opts = Map.new(opts)
  name = Map.get(opts, :name, YellowDog.Dns)
  opts = Map.put(opts, :name, name)

  Telemetry.debug("Starting DNS supervisor")
  Supervisor.start_link(__MODULE__, opts, name: name)
end
```

### Step 2: Add ViewManager to Supervisor Children

In `build_children/1`, add View.Manager before Server:

```elixir
# Add to build_children/1:
{YellowDog.Dns.View.Manager, view_manager_opts}
|> Supervisor.child_spec(id: :view_manager),
```

### Step 3: Fix DNS Handler

Edit `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`:

Remove inline process creation from `init/1`:

```elixir
# REMOVE these lines from init/1:
# {:ok, view_manager_pid} = ViewManager.start_link(views: initial_views, name: nil)
# config_watcher_pid = start_config_watcher_if_enabled(view_manager_pid)

# REPLACE with:
# View.Manager is now managed by supervisor, use named process
view_manager = YellowDog.Dns.View.Manager
```

### Step 4: Add Dashboard Event Handlers

Edit `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`:

```elixir
def handle_event("start_service", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)

  case YellowDog.start_service(service) do
    :ok ->
      {:noreply,
       socket
       |> assign(:services, get_service_status())
       |> put_flash(:info, "#{service_str} started successfully")}

    {:error, reason} ->
      {:noreply,
       put_flash(socket, :error, "Failed to start #{service_str}: #{inspect(reason)}")}
  end
end

def handle_event("stop_service", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)

  case YellowDog.stop_service(service) do
    :ok ->
      {:noreply,
       socket
       |> assign(:services, get_service_status())
       |> put_flash(:info, "#{service_str} stopped successfully")}

    {:error, reason} ->
      {:noreply,
       put_flash(socket, :error, "Failed to stop #{service_str}: #{inspect(reason)}")}
  end
end
```

### Step 5: Add Dashboard Buttons

Edit `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`:

In the `<:actions>` slot of service cards:

```heex
<:actions>
  <%= if service.running do %>
    <button
      class="btn btn-sm btn-error gap-2"
      phx-click="stop_service"
      phx-value-service={service.key}
    >
      <Heroicons.stop solid class="w-4 h-4" />
      Stop
    </button>
  <% else %>
    <button
      class="btn btn-sm btn-success gap-2"
      phx-click="start_service"
      phx-value-service={service.key}
    >
      <Heroicons.play solid class="w-4 h-4" />
      Start
    </button>
  <% end %>
  <button class="btn btn-sm btn-ghost gap-2">
    <Heroicons.cog_6_tooth solid class="w-4 h-4" />
    Configure
  </button>
</:actions>
```

## Testing

### Unit Tests

```bash
# Run DNS tests
mix test apps/yellow_dog_dns/test/

# Run console tests
mix test apps/yellow_dog_console/test/
```

### Manual Testing

```bash
# Start Phoenix server
cd apps/yellow_dog_console
iex -S mix phx.server

# Open browser to http://localhost:4000/dashboard
# Click Start on DNS service card
# Verify status changes to "Running"
# Click Stop
# Verify status changes to "Stopped"
```

### DNS Query Test

```bash
# After starting DNS service via dashboard
dig @127.0.0.1 -p 53 example.com A

# Or use dnsperf for load testing
echo "example.com A" > /tmp/queries.txt
dnsperf -n 100 -d /tmp/queries.txt -s 127.0.0.1 -p 53
```

## Verification Checklist

- [ ] DNS supervisor starts without returning `:ignore`
- [ ] ViewManager is in supervisor tree (check `Supervisor.which_children/1`)
- [ ] DNS service starts via dashboard "Start" button
- [ ] DNS service stops via dashboard "Stop" button
- [ ] Status updates reflect in UI within 5 seconds
- [ ] DNS responds to queries after starting
- [ ] Code compiles with `--warnings-as-errors`
- [ ] All tests pass (`mix test`)

## Troubleshooting

### DNS Still Returns `:ignore`

Check that the conditional was fully removed from `start_link/1`:

```elixir
# Should NOT contain:
unless apply(YellowDog.Config, :service_enabled?, [:dns]) do
```

### ViewManager Not Found

Ensure ViewManager is added to supervisor children with proper child_spec:

```elixir
{YellowDog.Dns.View.Manager, opts}
|> Supervisor.child_spec(id: :view_manager),
```

### Dashboard Buttons Not Working

Check that `phx-click` and `phx-value-service` attributes are correctly set:

```heex
phx-click="start_service"
phx-value-service={service.key}
```

### Port 53 Permission Denied

Use non-privileged port in test/dev:

```toml
# config.toml
[dns]
port = 5353
```

Or run with elevated privileges:

```bash
sudo -E iex -S mix phx.server
```

## Reference Implementation

For working service patterns, examine:

- `apps/yellow_dog_mdns/lib/yellow_dog/mdns/supervisor.ex` - Supervisor pattern
- `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/supervisor.ex` - Child management
- `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex` - Event handling
