# Implementation Plan: Console Settings Management

**Branch**: `001-console-settings` | **Date**: 2025-11-10 | **Spec**: [spec.md](./spec.md)

## Summary

Add a `/settings` route to the Yellow Dog web console for managing service configurations (DNS, mDNS, DHCPv4, DHCPv6) through a tabbed interface. The feature implements staged configuration changes with optimistic locking, full CRUD pool management for DHCP services, and configuration file recovery mechanisms. Configuration changes are saved to TOML files and marked as "pending" until explicitly applied per-service, with automatic service restart on apply.

## Technical Context

**Language/Version**: Elixir 1.18 with OTP 27/28
**Primary Dependencies**: Phoenix 1.8.1, Phoenix LiveView 1.1.17, DaisyUI 5.0.35, Tailwind CSS 4.1.11, Toml 0.7.0
**Storage**: TOML configuration files, ETS for configuration version tracking
**Testing**: ExUnit with LiveView testing, integration tests for TOML I/O
**Target Platform**: Web browser (desktop/tablet/mobile responsive)
**Project Type**: Web application (Phoenix LiveView within umbrella project)
**Performance Goals**:
- Page load < 2 seconds
- Save operation < 3 seconds (95th percentile)
- Real-time validation feedback < 100ms

**Constraints**:
- Must preserve TOML file structure and comments
- Must support concurrent administrators with optimistic locking
- Must validate IP addresses (IPv4/IPv6) and port ranges
- Must handle missing/corrupted configuration files gracefully

**Scale/Scope**:
- 4 service tabs (DNS, mDNS, DHCPv4, DHCPv6)
- Up to 20 configuration fields per service
- Up to 10 DHCP pools per service
- Single TOML configuration file
- Expected < 10 concurrent administrators

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Module Naming ✅
- **Status**: PASS
- **Compliance**: New LiveView modules will follow `YellowDog.Console.SettingsLive` pattern
- **Location**: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex`

### Phoenix LiveView Architecture ✅
- **Status**: PASS
- **Compliance**:
  - Use `use YellowDog.Console, :live_view` for LiveView modules
  - Use `use YellowDog.Console, :html` for function components
  - Leverage existing DaisyUI components (`<.card>`, `<.modal>`, `<.table>`, `<.badge>`, etc.)
  - Follow Phoenix 1.8 function component patterns

### Asset Building ✅
- **Status**: PASS
- **Compliance**:
  - No custom JavaScript needed initially (Phoenix LiveView handles interactivity)
  - Tailwind CSS for styling (already configured)
  - DaisyUI components (already available)
  - If JavaScript needed: use Bun build system (already configured)

### Configuration Management ✅
- **Status**: PASS
- **Compliance**:
  - Use `YellowDog.Config` module for reading configuration
  - Write TOML using Toml library (decode-only, custom encoder exists in codebase)
  - Preserve existing TOML structure when saving

### Code Quality ✅
- **Status**: PASS
- **Requirements**:
  - Compile with `--warnings-as-errors`
  - Format with `mix format`
  - Lint with `mix credo --strict`
  - Type check with `mix dialyzer`
  - Test with ExUnit

### Testing ✅
- **Status**: PASS
- **Requirements**:
  - LiveView testing with `Phoenix.LiveViewTest`
  - Unit tests for validation logic
  - Integration tests for TOML save/load
  - Test file permissions and error handling

### Telemetry ✅
- **Status**: PASS
**Compliance**: Emit telemetry events for:
  - Configuration load/save operations
  - Validation errors
  - Apply changes operations
  - Service restart events

### HTTP Transport ✅
- **Status**: NOT APPLICABLE
- **Rationale**: Feature does not make external HTTP requests

### Infrastructure Libraries ✅
- **Status**: NOT APPLICABLE
- **Rationale**: Feature uses existing infrastructure (Phoenix, LiveView), no changes to abyss/ex_dns/ex_dhcp

## Project Structure

### Documentation (this feature)

```text
specs/001-console-settings/
├── plan.md              # This file
├── spec.md              # Feature specification (completed)
├── research.md          # Phase 0 output (to be generated)
├── data-model.md        # Phase 1 output (to be generated)
├── quickstart.md        # Phase 1 output (to be generated)
├── contracts/           # Phase 1 output (to be generated)
│   └── settings-api.md  # LiveView message contracts
└── tasks.md             # Phase 2 output (not created yet)
```

### Source Code (repository root)

```text
apps/yellow_dog_console/
├── lib/yellow_dog/console/
│   ├── live/
│   │   ├── settings_live.ex              # Main settings page LiveView
│   │   ├── settings_live/
│   │   │   ├── dns_component.ex          # DNS tab component
│   │   │   ├── mdns_component.ex         # mDNS tab component
│   │   │   ├── dhcpv4_component.ex       # DHCPv4 tab component
│   │   │   ├── dhcpv6_component.ex       # DHCPv6 tab component
│   │   │   ├── pool_form_component.ex    # Pool create/edit modal
│   │   │   └── recovery_modal_component.ex # Configuration recovery modal
│   │   └── router.ex                     # Add /settings route
│   ├── config_manager.ex                 # Configuration file I/O module
│   └── validators.ex                     # Input validation functions
├── test/yellow_dog/console/
│   ├── live/settings_live_test.exs       # LiveView integration tests
│   ├── config_manager_test.exs           # TOML I/O tests
│   └── validators_test.exs               # Validation unit tests
└── priv/static/                          # Assets (no changes needed)

apps/yellow_dog/
├── lib/yellow_dog/
│   └── config.ex                         # Add: update/2, get_version/0, compare_and_swap/3
└── test/yellow_dog/
    └── config_test.exs                   # Add tests for new functions
```

**Structure Decision**: Web application structure within the `apps/yellow_dog_console` umbrella application. Configuration management logic added to core `apps/yellow_dog` application. This follows the existing pattern where console provides UI and core provides business logic.

## Complexity Tracking

> **No constitutional violations detected.** This section is empty.

## Phase 0: Research & Technology Decisions

### Research Topics

1. **Phoenix LiveView Form Validation Patterns**
   - **Question**: How to implement real-time client-side validation in LiveView without custom JavaScript?
   - **Approach**: Research `phx-change` events, `Phoenix.HTML.Form` validation, and DaisyUI error states
   - **Output**: Validation strategy in research.md

2. **TOML File Preservation Strategy**
   - **Question**: How to update TOML file while preserving structure, comments, and formatting?
   - **Approach**: Research Toml library capabilities, investigate custom TOML encoder patterns in codebase
   - **Output**: TOML save/load strategy in research.md

3. **Optimistic Locking Implementation**
   - **Question**: How to detect concurrent modifications in distributed LiveView sessions?
   - **Approach**: Research ETS-based versioning, file modification timestamps, content hashing
   - **Output**: Concurrency control strategy in research.md

4. **Configuration Backup Strategy**
   - **Question**: When and how to create configuration backups automatically?
   - **Approach**: Research backup-before-save patterns, rotation policies, recovery UI
   - **Output**: Backup mechanism in research.md

5. **Service Restart Mechanism**
   - **Question**: How to safely restart a service programmatically from the console?
   - **Approach**: Research OTP supervisor restart strategies, `YellowDog.ServiceManager` integration
   - **Output**: Service restart pattern in research.md

### Technology Stack Confirmed

Based on constitution and existing codebase:

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **Web Framework** | Phoenix 1.8.1 | Existing in yellow_dog_console |
| **Real-time UI** | Phoenix LiveView 1.1.17 | Existing, no custom JavaScript needed |
| **UI Components** | DaisyUI 5.0.35 | Existing component library |
| **Styling** | Tailwind CSS 4.1.11 | Existing utility-first CSS |
| **Configuration Format** | TOML 0.7.0 | Existing, matches yellow_dog core |
| **Validation** | LiveView changesets + custom validators | Standard Phoenix pattern |
| **State Management** | LiveView assigns + ETS | Standard LiveView pattern |
| **Asset Building** | Bun (if custom JS needed) | Existing in yellow_dog_console |

## Phase 1: Design Artifacts

### Data Model (to be generated in data-model.md)

**Entities**:
1. **ServiceConfiguration** - DNS, mDNS, DHCPv4, DHCPv6 settings
2. **AddressPool** - DHCP pool definitions
3. **ConfigurationVersion** - Optimistic lock tracking
4. **PendingChange** - Staged configuration state

### API Contracts (to be generated in contracts/)

**LiveView Message Contracts**:
1. **Settings Page Events**:
   - `load_configuration` - Initial page load
   - `switch_tab` - Tab navigation
   - `save_configuration` - Save pending changes
   - `apply_changes` - Activate pending configuration
   - `reload_configuration` - Refresh from file (conflict resolution)
   - `recover_configuration` - Handle missing/corrupt file

2. **Pool Management Events**:
   - `add_pool` - Create new pool
   - `edit_pool` - Modify existing pool
   - `delete_pool` - Remove pool (with confirmation)
   - `validate_pool` - Real-time pool validation

3. **Validation Events**:
   - `validate_field` - Real-time field validation on phx-change
   - `check_overlapping_ranges` - Pool range conflict detection

### Quickstart Guide (to be generated in quickstart.md)

**Developer Quickstart**:
1. Navigate to http://localhost:4000/settings
2. Select service tab (DNS/mDNS/DHCPv4/DHCPv6)
3. Edit configuration fields
4. Click "Save" to stage changes
5. Click "Apply Changes" to restart service with new configuration

**Testing Quickstart**:
```bash
# Run LiveView tests
mix test apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs

# Run config manager tests
mix test apps/yellow_dog_console/test/yellow_dog/console/config_manager_test.exs

# Run with coverage
mix test --cover
```

## Implementation Notes

### LiveView Architecture

**Main LiveView**: `YellowDog.Console.SettingsLive`
- Manages tab state (active tab: :dns | :mdns | :dhcpv4 | :dhcpv6)
- Loads configuration on mount
- Dispatches events to tab components
- Handles global actions (save, apply, reload, recover)
- Tracks pending changes per service
- Implements optimistic locking

**Tab Components**: Function components for each service
- `dns_component.ex` - DNS configuration form
- `mdns_component.ex` - mDNS configuration form
- `dhcpv4_component.ex` - DHCPv4 configuration + pool list
- `dhcpv6_component.ex` - DHCPv6 configuration + pool list

**Modal Components**:
- `pool_form_component.ex` - Live component for pool CRUD
- `recovery_modal_component.ex` - Configuration recovery options

### Configuration Management

**YellowDog.Console.ConfigManager Module**:
```elixir
defmodule YellowDog.Console.ConfigManager do
  @moduledoc """
  Handles TOML configuration file I/O with structure preservation.
  """

  @spec load_config(String.t()) :: {:ok, map()} | {:error, term()}
  def load_config(file_path)

  @spec save_config(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_config(file_path, config, opts \\ [])

  @spec create_backup(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_backup(file_path)

  @spec list_backups(String.t()) :: [String.t()]
  def list_backups(file_path)
end
```

**YellowDog.Config Extensions**:
```elixir
# Add to apps/yellow_dog/lib/yellow_dog/config.ex

@spec get_version() :: non_neg_integer()
def get_version()

@spec update(map()) :: :ok | {:error, term()}
def update(new_config)

@spec compare_and_swap(map(), non_neg_integer()) :: :ok | {:error, :version_mismatch | term()}
def compare_and_swap(new_config, expected_version)
```

### Validation Strategy

**YellowDog.Console.Validators Module**:
```elixir
defmodule YellowDog.Console.Validators do
  @spec validate_ipv4(String.t()) :: :ok | {:error, String.t()}
  def validate_ipv4(address)

  @spec validate_ipv6(String.t()) :: :ok | {:error, String.t()}
  def validate_ipv6(address)

  @spec validate_port(integer()) :: :ok | {:error, String.t()}
  def validate_port(port)

  @spec validate_pool_range(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_pool_range(start_ip, end_ip)

  @spec check_overlapping_pools([map()]) :: :ok | {:error, String.t()}
  def check_overlapping_pools(pools)
end
```

### Pending Changes Workflow

1. **Initial Load**:
   - Load configuration from TOML file
   - Store version/timestamp in assigns
   - Display current active configuration

2. **Edit**:
   - User modifies fields in form
   - Real-time validation on `phx-change`
   - Changes stored in `pending_changes` assign
   - Save button enabled when valid changes exist

3. **Save**:
   - Validate all fields
   - Check version (optimistic lock)
   - Write to TOML file
   - Mark as "pending" in UI
   - Display success toast

4. **Apply**:
   - Per-service apply button
   - Reload configuration into YellowDog.Config
   - Restart only affected service via Supervisor
   - Clear "pending" indicator
   - Display success toast

### Error Handling

**Configuration File Missing/Corrupted**:
1. Detect on page load
2. Display recovery modal with options:
   - "Use Default Configuration" - Load built-in defaults
   - "Restore from Backup" - Select from backup list
   - "Create New Configuration" - Initialize minimal config
3. Disable editing until recovery option selected

**Concurrent Modification (Optimistic Lock Failure)**:
1. Detect version mismatch on save
2. Display error modal with:
   - Explanation of conflict
   - Current file contents
   - User's pending changes
   - Actions: "Reload and Discard", "Cancel"
3. On reload, refresh page with current configuration

**Service Restart Failure**:
1. Detect failure in apply operation
2. Display error message with details
3. Keep pending configuration (user can retry or revert)
4. Log error for administrator review

## Routing

**Add to `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`**:

```elixir
scope "/", YellowDog.Console do
  pipe_through :browser

  # Existing routes...
  live "/settings", SettingsLive
end
```

## Telemetry Events

Emit the following telemetry events:

```elixir
# Configuration operations
:telemetry.execute(
  [:yellow_dog, :console, :config, :load],
  %{duration: duration_ms},
  %{source: :file}
)

:telemetry.execute(
  [:yellow_dog, :console, :config, :save],
  %{duration: duration_ms},
  %{service: :dns, pending: true}
)

:telemetry.execute(
  [:yellow_dog, :console, :config, :apply],
  %{duration: duration_ms},
  %{service: :dhcpv4, success: true}
)

# Validation events
:telemetry.execute(
  [:yellow_dog, :console, :validation, :error],
  %{count: 1},
  %{field: :port, error: :out_of_range}
)

# Conflict resolution
:telemetry.execute(
  [:yellow_dog, :console, :config, :conflict],
  %{count: 1},
  %{action: :reload}
)
```

## Phase Completion Status

### Phase 0: Research & Technology Decisions ✅ COMPLETE
- [x] Generated `research.md` with 5 research topics resolved
- [x] All NEEDS CLARIFICATION items addressed
- [x] Technical decisions documented with rationale

**Research Topics Completed**:
1. Phoenix LiveView Form Validation Patterns → Ecto embedded schemas + phx-change events
2. TOML File Preservation Strategy → Line-based partial update with token parsing
3. Optimistic Locking Implementation → Hybrid version counter + file timestamp
4. Configuration Backup Strategy → Before-every-save with 10-backup rotation
5. Service Restart Mechanism → OTP terminate-and-restart via supervisor

### Phase 1: Design Artifacts ✅ COMPLETE
- [x] Generated `data-model.md` with 4 entity definitions
- [x] Generated `contracts/settings-api.md` with 12 LiveView events
- [x] Generated `quickstart.md` with developer setup guide

**Artifacts Created**:
1. **data-model.md**: ServiceConfiguration, AddressPool, ConfigurationVersion, PendingChange entities with Ecto schemas
2. **contracts/settings-api.md**: Complete LiveView event contracts with implementations
3. **quickstart.md**: Local development setup, testing workflows, troubleshooting guide

### Phase 2: Task Breakdown (Next)
- [ ] Generate `tasks.md` with atomic implementation tasks
- [ ] Run `/speckit.tasks` command to create task breakdown
- [ ] Validate task dependencies and ordering

---

## Next Steps

1. **Run `/speckit.tasks`** to generate implementation task breakdown
2. **Update CLAUDE.md** via `.specify/scripts/bash/update-agent-context.sh claude`
3. **Begin implementation** starting with Phase 2 tasks

---

**Status**: Phase 0 and Phase 1 COMPLETE. Ready for Phase 2 task generation via `/speckit.tasks`.
