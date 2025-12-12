# Research: DNS Service Implementation Fix and Dashboard Service Controls

**Branch**: `001-dns-service` | **Date**: 2025-12-10

## Research Topics

1. DNS Service Architecture Issues
2. Working Service Patterns (mDNS, DHCPv4)
3. Dashboard Service Control Implementation
4. Service Manager API

---

## 1. DNS Service Architecture Issues

### Decision: Remove `:ignore` Check from DNS Supervisor

**Rationale**: The DNS supervisor incorrectly checks `service_enabled?(:dns)` and returns `:ignore`. This is handled at the application layer in `YellowDog.Application.get_enabled_services/1` which filters services before starting their supervisors.

**Alternatives Considered**:
- Keep `:ignore` check for defense-in-depth → Rejected: Creates inconsistency with working services and causes confusion
- Move all filtering to supervisors → Rejected: Violates existing architecture pattern

**Evidence**:
- `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex:28-41` - DNS has `:ignore` check
- `apps/yellow_dog_mdns/lib/yellow_dog/mdns/supervisor.ex:21-26` - mDNS has NO `:ignore` check
- `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/supervisor.ex:24-30` - DHCPv4 has NO `:ignore` check
- `apps/yellow_dog/lib/yellow_dog/application.ex:252-269` - Application filters services

---

### Decision: Move ViewManager to Supervisor Tree

**Rationale**: The DNS handler creates ViewManager inline in its `init/1` callback at line 67. This violates OTP supervision principles and prevents crash recovery.

**Alternatives Considered**:
- Keep inline creation with process linking → Rejected: Handler is not a supervisor, cannot properly restart children
- Create a separate manager supervisor → Rejected: Over-engineering; add to existing DNS supervisor

**Evidence**:
- `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex:67` - `{:ok, view_manager_pid} = ViewManager.start_link(views: initial_views, name: nil)`
- `apps/yellow_dog_mdns/lib/yellow_dog/mdns/supervisor.ex:62-65` - mDNS adds ServiceRegistry to children
- `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/supervisor.ex:50-52` - DHCPv4 adds LeaseManager to children

---

### Decision: Move ConfigWatcher to Supervisor Tree

**Rationale**: Similar to ViewManager, ConfigWatcher is started inline in handler. Should be a supervised child for proper lifecycle management.

**Alternatives Considered**:
- Optional GenServer started on-demand → Rejected: Still needs supervision for crash recovery
- Periodic polling instead of watcher → Rejected: Less efficient for file-based config

**Evidence**:
- `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex:1142` - `start_config_watcher_if_enabled/1` creates inline

---

## 2. Working Service Patterns (mDNS, DHCPv4)

### Decision: Follow mDNS Supervisor Pattern

**Rationale**: mDNS supervisor is production-ready and demonstrates the correct architecture pattern.

**Pattern Structure** (from `apps/yellow_dog_mdns/lib/yellow_dog/mdns/supervisor.ex:59-94`):
```elixir
defp build_children(opts) do
  [
    # 1. Service managers (dependencies first)
    {YellowDog.Mdns.ServiceRegistry, registry_opts}
    |> Supervisor.child_spec(id: :service_registry),

    # 2. File watchers (optional)
    {YellowDog.Mdns.FileWatcher, watcher_opts}
    |> Supervisor.child_spec(id: :file_watcher),

    # 3. Network monitor (optional)
    {YellowDog.Mdns.Monitor, monitor_opts}
    |> Supervisor.child_spec(id: :network_monitor),

    # 4. Server (depends on above)
    {YellowDog.Mdns.Server, server_options}
    |> Supervisor.child_spec(id: :server),
  ]
end
```

**Key Principles**:
1. All child processes in supervisor tree
2. Dependencies started before dependents
3. Proper child_spec with unique IDs
4. Handler receives registry names, not PIDs

**Alternatives Considered**:
- Custom supervision tree → Rejected: Unnecessary complexity
- Application-level supervision → Rejected: Services should be self-contained

---

## 3. Dashboard Service Control Implementation

### Decision: Use Existing YellowDog.start_service/stop_service API

**Rationale**: The service control API already exists and is tested. Dashboard just needs UI and event handlers.

**API Available** (from `apps/yellow_dog/lib/yellow_dog.ex:143-167`):
```elixir
@spec start_service(atom()) :: :ok | {:error, term()}
defdelegate start_service(service), to: YellowDog.ServiceManager

@spec stop_service(atom()) :: :ok | {:error, term()}
defdelegate stop_service(service), to: YellowDog.ServiceManager
```

**Implementation Flow**:
1. User clicks Start/Stop button
2. `phx-click="start_service|stop_service"` triggers event
3. `handle_event/3` calls `YellowDog.start_service/1` or `YellowDog.stop_service/1`
4. ServiceManager updates config and starts/stops supervisor
5. Flash message shows result
6. Periodic refresh updates status display

**Alternatives Considered**:
- Create new API specifically for dashboard → Rejected: Duplicates existing functionality
- Direct supervisor manipulation → Rejected: Bypasses config layer

---

### Decision: Add Buttons in Service Card `:actions` Slot

**Rationale**: Dashboard already uses `<.card>` component with `:actions` slot. Add Start/Stop buttons following DaisyUI patterns.

**Current Template** (`apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex:115-137`):
```heex
<:actions>
  <button class="btn btn-sm btn-ghost gap-2">
    <Heroicons.cog_6_tooth solid class="w-4 h-4" />
    Configure
  </button>
</:actions>
```

**Proposed Addition**:
```heex
<:actions>
  <%= if service.running do %>
    <button
      class="btn btn-sm btn-error gap-2"
      phx-click="stop_service"
      phx-value-service={service.key}
    >
      Stop
    </button>
  <% else %>
    <button
      class="btn btn-sm btn-success gap-2"
      phx-click="start_service"
      phx-value-service={service.key}
    >
      Start
    </button>
  <% end %>
  <!-- existing Configure button -->
</:actions>
```

**Alternatives Considered**:
- Modal confirmation dialog → Rejected: Adds complexity; simple toggle is sufficient
- Separate control panel → Rejected: Service controls belong with service display

---

## 4. Service Manager API

### Decision: Leverage Existing ServiceManager Implementation

**Rationale**: `YellowDog.ServiceManager` is fully implemented with start/stop functionality.

**Available Functions** (from `apps/yellow_dog/lib/yellow_dog/service_manager.ex`):

| Function | Lines | Purpose |
|----------|-------|---------|
| `start_service/1` | 95-107 | Enable service and start supervisor |
| `stop_service/1` | 125-137 | Disable service and stop supervisor |
| `get_service_status/1` | 44-71 | Get full service status |
| `get_all_status/0` | 26-32 | Get all services status |

**Implementation Details**:
- Updates config via `YellowDog.Config.set_service_enabled/2`
- Starts/stops supervisor via `YellowDog.Application.start_service_supervisor/2`
- Returns `:ok` or `{:error, reason}`

**Alternatives Considered**:
- Create new console-specific manager → Rejected: Duplicates functionality
- Direct OTP calls → Rejected: Bypasses config persistence

---

## Summary of Decisions

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Remove `:ignore` from DNS supervisor | Application layer handles filtering | Aligns with mDNS/DHCPv4 pattern |
| Move ViewManager to supervisor tree | Proper OTP supervision | Enables crash recovery |
| Move ConfigWatcher to supervisor tree | Proper lifecycle management | Enables crash recovery |
| Follow mDNS supervisor pattern | Production-ready reference | Consistent architecture |
| Use existing start_service/stop_service API | Already implemented and tested | Minimal new code |
| Add buttons in `:actions` slot | Follows existing UI patterns | Consistent UX |

---

## Files Requiring Changes

1. `apps/yellow_dog_dns/lib/yellow_dog/dns/supervisor.ex`
   - Remove lines 28-32 (`:ignore` check)
   - Add View.Manager and ConfigWatcher to `build_children/1`

2. `apps/yellow_dog_dns/lib/yellow_dog/dns/handler/udp.ex`
   - Remove ViewManager.start_link() from `init/1`
   - Remove ConfigWatcher creation from handler
   - Update state to use named process instead of PID

3. `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
   - Add `handle_event("start_service", ...)` (~15 lines)
   - Add `handle_event("stop_service", ...)` (~15 lines)

4. `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
   - Add Start/Stop buttons in `:actions` slot (~20 lines)
