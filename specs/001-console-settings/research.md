# Research Findings: Console Settings Management

**Feature**: Console Settings Management (001-console-settings)
**Date**: 2025-11-10
**Phase**: Phase 0 - Research & Technology Decisions
**Plan**: [plan.md](./plan.md)

## Research Overview

This document consolidates findings from 5 research tasks executed during Phase 0. All NEEDS CLARIFICATION items from the plan have been resolved with concrete technical decisions.

---

## Research Topic 1: Phoenix LiveView Form Validation Patterns

### Decision

Use **Ecto embedded schemas with changesets** for form validation combined with **phx-change events** for real-time feedback and **DaisyUI error states** for UI display.

### Rationale

1. **No Custom JavaScript Required**: LiveView's `phx-change` events provide real-time validation without client-side code
2. **Reusable Validation Logic**: Ecto changesets centralize validation rules that can be tested independently
3. **DaisyUI Integration**: Error states are built into DaisyUI form components
4. **Type Safety**: Embedded schemas provide compile-time guarantees for field types
5. **Standard Phoenix Pattern**: Follows Phoenix 1.8 best practices

### Implementation Pattern

```elixir
defmodule YellowDog.Console.Settings.DnsConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: true
    field :listen, :string
    field :port, :integer
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:enabled, :listen, :port])
    |> validate_required([:enabled, :listen, :port])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)
    |> validate_change(:listen, &validate_ip_address/2)
  end

  defp validate_ip_address(:listen, address) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, _} -> []
      {:error, _} -> [listen: "must be a valid IP address"]
    end
  end
end
```

**LiveView Usage**:
```elixir
def handle_event("validate", %{"dns_config" => params}, socket) do
  changeset =
    socket.assigns.dns_config
    |> DnsConfig.changeset(params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, :changeset, changeset)}
end
```

**Template with DaisyUI Error States**:
```heex
<.form for={@changeset} phx-change="validate" phx-submit="save">
  <div class="form-control">
    <label class="label">
      <span class="label-text">Listen Address</span>
    </label>
    <.input
      field={@changeset[:listen]}
      type="text"
      class={["input input-bordered", @changeset.errors[:listen] && "input-error"]}
    />
    <%= if error = @changeset.errors[:listen] do %>
      <label class="label">
        <span class="label-text-alt text-error"><%= elem(error, 0) %></span>
      </label>
    <% end %>
  </div>
</.form>
```

### Alternatives Considered

1. **Client-Side Validation with JavaScript Hooks**
   - Rejected: Violates constitution requirement for minimal custom JavaScript
   - Adds complexity and maintenance burden

2. **Server-Side Validation Only (on submit)**
   - Rejected: Poor UX - users don't see errors until form submission
   - Doesn't meet "real-time validation feedback < 100ms" performance goal

3. **Custom Validation Module without Ecto**
   - Rejected: Reinvents the wheel, loses Ecto's testing utilities
   - No built-in error tracking like changesets provide

### Key Patterns

- **Debouncing**: Use `phx-debounce="300"` on text inputs to reduce validation frequency
- **Multi-Field Validation**: Use `validate_change/3` with access to entire changeset
- **Conditional Validation**: Use `validate_required/3` with conditional logic based on other fields
- **IP Address Validation**: Use `:inet.parse_address/1` for IPv4/IPv6 validation
- **Pool Overlap Detection**: Custom validator accessing all pools via socket assigns

---

## Research Topic 2: TOML File Preservation Strategy

### Decision

Implement a **line-based partial update system** with token parsing that updates only changed values while preserving all comments, whitespace, and formatting.

### Rationale

1. **TOML Library Limitation**: Toml 0.7.0 is decode-only (no encoder)
2. **Comment Preservation**: Full parse-serialize would lose all comments and formatting
3. **Existing Codebase Pattern**: Yellow Dog already has custom TOML encoding in `YellowDog.Mdns.ServiceStore`
4. **Minimal Changes**: Only updates lines containing changed values
5. **Atomic Writes**: Uses temp file + rename pattern for crash safety

### Implementation Pattern

**Core Algorithm**:
```elixir
defmodule YellowDog.Console.ConfigManager do
  @moduledoc """
  Handles TOML configuration file I/O with structure preservation.
  """

  @doc """
  Partially updates TOML file, preserving comments and formatting.

  ## Options
  - `:backup` - Create backup before save (default: true)
  - `:verify` - Verify parse after save (default: true)
  """
  @spec save_config(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_config(file_path, updates, opts \\ []) do
    with {:ok, content} <- File.read(file_path),
         :ok <- maybe_backup(file_path, opts),
         {:ok, updated_content} <- apply_updates(content, updates),
         :ok <- atomic_write(file_path, updated_content),
         :ok <- maybe_verify(file_path, opts) do
      :ok
    end
  end

  defp apply_updates(content, updates) do
    lines = String.split(content, "\n")
    tokens = parse_tokens(lines)
    updated_lines = update_lines(lines, tokens, updates)
    {:ok, Enum.join(updated_lines, "\n")}
  end

  defp parse_tokens(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {line, idx}, {tokens, section} ->
      cond do
        String.match?(line, ~r/^\[(.+)\]$/) ->
          section_name = Regex.run(~r/^\[(.+)\]$/, line) |> List.last()
          {tokens, section_name}

        String.match?(line, ~r/^(\w+)\s*=/) ->
          [key | _] = String.split(line, "=")
          key = String.trim(key)
          full_key = if section, do: "#{section}.#{key}", else: key
          {[{full_key, idx} | tokens], section}

        true ->
          {tokens, section}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp update_lines(lines, tokens, updates) do
    Enum.map(lines, fn line ->
      Enum.reduce(updates, line, fn {key_path, new_value}, acc ->
        case Map.get(tokens, key_path) do
          nil -> acc
          _line_idx -> update_line_value(acc, key_path, new_value)
        end
      end)
    end)
  end

  defp update_line_value(line, key, value) do
    key_name = key |> String.split(".") |> List.last()
    encoded_value = encode_toml_value(value)

    Regex.replace(
      ~r/^(\s*#{key_name}\s*=\s*).*$/,
      line,
      "\\1#{encoded_value}"
    )
  end

  defp encode_toml_value(value) when is_binary(value), do: "\"#{value}\""
  defp encode_toml_value(value) when is_boolean(value), do: to_string(value)
  defp encode_toml_value(value) when is_integer(value), do: to_string(value)
  defp encode_toml_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &encode_toml_value/1) <> "]"
  end
  defp encode_toml_value(value) when is_map(value) do
    # Inline table: {key = "value", key2 = 123}
    "{" <> Enum.map_join(value, ", ", fn {k, v} ->
      "#{k} = #{encode_toml_value(v)}"
    end) <> "}"
  end

  defp atomic_write(file_path, content) do
    temp_path = "#{file_path}.tmp"

    with :ok <- File.write(temp_path, content),
         :ok <- File.rename(temp_path, file_path) do
      :ok
    else
      error ->
        File.rm(temp_path)
        error
    end
  end

  defp maybe_verify(file_path, opts) do
    if Keyword.get(opts, :verify, true) do
      case Toml.decode_file(file_path) do
        {:ok, _} -> :ok
        error -> {:error, {:verification_failed, error}}
      end
    else
      :ok
    end
  end
end
```

**Backup Management**:
```elixir
defp maybe_backup(file_path, opts) do
  if Keyword.get(opts, :backup, true) do
    create_backup(file_path)
  else
    :ok
  end
end

@spec create_backup(String.t()) :: {:ok, String.t()} | {:error, term()}
def create_backup(file_path) do
  timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
  backup_path = "#{file_path}.backup.#{timestamp}"

  with :ok <- rotate_backups(file_path, max_backups: 10),
       :ok <- File.copy(file_path, backup_path) do
    {:ok, backup_path}
  end
end

defp rotate_backups(file_path, opts) do
  max_backups = Keyword.get(opts, :max_backups, 10)

  backups = list_backups(file_path)
  to_delete = Enum.drop(backups, -(max_backups - 1))

  Enum.each(to_delete, &File.rm/1)
  :ok
end

@spec list_backups(String.t()) :: [String.t()]
def list_backups(file_path) do
  dir = Path.dirname(file_path)
  base = Path.basename(file_path)

  File.ls!(dir)
  |> Enum.filter(&String.starts_with?(&1, "#{base}.backup."))
  |> Enum.map(&Path.join(dir, &1))
  |> Enum.sort()
end
```

### Alternatives Considered

1. **Full Parse-Serialize with Toml Library**
   - Rejected: Library is decode-only, no encoder available
   - Would require adding new dependency or writing full TOML encoder

2. **Custom TOML Encoder (full AST approach)**
   - Rejected: Over-engineered for this use case
   - High complexity, difficult to preserve exact formatting

3. **Template-Based Generation**
   - Rejected: Inflexible, requires maintaining separate template files
   - Doesn't preserve user customizations or comments

4. **String Replacement Only**
   - Rejected: Fragile, breaks on formatting variations
   - No parsing means no validation

### Key Patterns

- **Token Index**: Build map of `"section.key" => line_number` for fast lookup
- **Regex Updates**: Use regex capture groups to preserve indentation and spacing
- **Atomic Writes**: Always write to temp file, then rename (POSIX atomic operation)
- **Verification**: Parse updated file with Toml library to ensure validity
- **Backup Rotation**: Keep last 10 backups, delete oldest first

---

## Research Topic 3: Optimistic Locking Implementation

### Decision

Use a **hybrid approach** combining an in-memory version counter (ETS + Agent) with file modification timestamp for external change detection.

### Rationale

1. **Fast Version Check**: In-memory counter catches most web console conflicts instantly
2. **External Edit Detection**: File timestamp catches changes made outside console (CLI, editor)
3. **No Database Required**: Uses ETS for lightweight version tracking
4. **Low Overhead**: Version increment is a single Agent call
5. **Race Condition Safe**: Combine-and-compare pattern is atomic

### Implementation Pattern

**Configuration Version Tracker**:
```elixir
defmodule YellowDog.Console.ConfigVersionTracker do
  use Agent

  @moduledoc """
  Tracks configuration versions for optimistic locking.
  Uses ETS for fast lookups and Agent for state management.
  """

  def start_link(_opts) do
    Agent.start_link(fn ->
      :ets.new(:config_versions, [:set, :public, :named_table])
      %{current_version: 0}
    end, name: __MODULE__)
  end

  @doc "Get current version and file timestamp"
  @spec get_version(String.t()) :: %{version: non_neg_integer(), timestamp: integer()}
  def get_version(file_path) do
    version = Agent.get(__MODULE__, fn state -> state.current_version end)
    timestamp = get_file_timestamp(file_path)

    %{version: version, timestamp: timestamp}
  end

  @doc "Compare and swap: update version only if current matches expected"
  @spec compare_and_swap(String.t(), non_neg_integer(), integer()) ::
    :ok | {:error, :version_mismatch | :file_modified}
  def compare_and_swap(file_path, expected_version, expected_timestamp) do
    current_timestamp = get_file_timestamp(file_path)

    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        state.current_version != expected_version ->
          {{:error, :version_mismatch}, state}

        current_timestamp != expected_timestamp ->
          {{:error, :file_modified}, state}

        true ->
          new_version = state.current_version + 1
          {:ok, %{state | current_version: new_version}}
      end
    end)
  end

  @doc "Force increment version (after external file modification)"
  def increment_version do
    Agent.update(__MODULE__, fn state ->
      %{state | current_version: state.current_version + 1}
    end)
  end

  defp get_file_timestamp(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      {:error, _} ->
        0
    end
  end
end
```

**LiveView Integration**:
```elixir
defmodule YellowDog.Console.SettingsLive do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.{ConfigManager, ConfigVersionTracker}

  def mount(_params, _session, socket) do
    config_path = YellowDog.Config.config_path()

    {:ok, config} = ConfigManager.load_config(config_path)
    version_info = ConfigVersionTracker.get_version(config_path)

    socket =
      socket
      |> assign(:config, config)
      |> assign(:config_version, version_info.version)
      |> assign(:config_timestamp, version_info.timestamp)
      |> assign(:pending_changes, %{})

    {:ok, socket}
  end

  def handle_event("save", %{"service" => service, "config" => params}, socket) do
    config_path = YellowDog.Config.config_path()

    case ConfigVersionTracker.compare_and_swap(
      config_path,
      socket.assigns.config_version,
      socket.assigns.config_timestamp
    ) do
      :ok ->
        # Proceed with save
        updates = build_updates(service, params)

        case ConfigManager.save_config(config_path, updates) do
          :ok ->
            # Update version tracking
            new_version_info = ConfigVersionTracker.get_version(config_path)

            socket =
              socket
              |> assign(:config_version, new_version_info.version)
              |> assign(:config_timestamp, new_version_info.timestamp)
              |> put_flash(:info, "Configuration saved successfully")

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, :version_mismatch} ->
        handle_conflict(socket, :version_mismatch)

      {:error, :file_modified} ->
        handle_conflict(socket, :file_modified)
    end
  end

  defp handle_conflict(socket, reason) do
    message = case reason do
      :version_mismatch ->
        "Configuration was modified by another administrator. Please reload the page."
      :file_modified ->
        "Configuration file was modified externally. Please reload the page."
    end

    socket =
      socket
      |> put_flash(:error, message)
      |> assign(:show_conflict_modal, true)

    {:noreply, socket}
  end
end
```

### Alternatives Considered

1. **Version Counter Only (no file timestamp)**
   - Rejected: Doesn't detect external file modifications (CLI, text editor)
   - Web console could overwrite manual changes

2. **File Timestamp Only (no version counter)**
   - Rejected: Race conditions possible with rapid saves
   - Timestamp granularity varies by filesystem (1s on ext4, 1ns on APFS)

3. **Content Hash (SHA256 of file)**
   - Rejected: More expensive than timestamp check
   - Requires full file read on every save attempt

4. **Database-Based Versioning**
   - Rejected: Over-engineered, requires database dependency
   - Adds persistence layer for ephemeral lock state

### Key Patterns

- **Fast Path**: Check version counter first (in-memory, instant)
- **Slow Path**: Only check file timestamp if version matches
- **Atomic CAS**: Compare-and-swap in single Agent operation
- **Conflict UI**: Modal with "Reload and Discard Changes" option
- **Post-Save Update**: Always refresh version + timestamp after successful save

---

## Research Topic 4: Configuration Backup Strategy

### Decision

Create a backup **before every save operation** with timestamp-based naming, keeping the **last 10 backups** with automatic rotation.

### Rationale

1. **Safety First**: Configuration corruption can break all services
2. **Low Storage Cost**: TOML files are small (< 10KB typically)
3. **Simple Recovery**: Recent backups always available for quick rollback
4. **Automatic Cleanup**: No manual maintenance required
5. **Audit Trail**: Timestamps provide history of configuration changes

### Implementation Pattern

**Backup Naming Convention**:
```
config.toml.backup.20251110T143052Z  # ISO 8601 basic format
config.toml.backup.20251110T150322Z
config.toml.backup.20251110T153041Z
```

**Backup Creation**:
```elixir
@doc """
Creates a timestamped backup of the configuration file.
Automatically rotates old backups to keep only the last 10.

Returns {:ok, backup_path} or {:error, reason}.
"""
@spec create_backup(String.t()) :: {:ok, String.t()} | {:error, term()}
def create_backup(file_path) do
  unless File.exists?(file_path) do
    {:error, :file_not_found}
  else
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[:\-\.]/, "")

    backup_path = "#{file_path}.backup.#{timestamp}"

    with :ok <- rotate_backups(file_path, max_backups: 10),
         {:ok, _} <- File.copy(file_path, backup_path) do
      emit_telemetry(:backup_created, %{path: backup_path})
      {:ok, backup_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end

@doc """
Lists all backup files for a given configuration file.
Returns sorted list of paths (oldest first).
"""
@spec list_backups(String.t()) :: [String.t()]
def list_backups(file_path) do
  dir = Path.dirname(file_path)
  base = Path.basename(file_path)
  pattern = "#{base}.backup.*"

  case File.ls(dir) do
    {:ok, files} ->
      files
      |> Enum.filter(&String.match?(&1, ~r/^#{Regex.escape(base)}\.backup\.\d{8}T\d{6}Z$/))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.sort()

    {:error, _} -> []
  end
end

@doc """
Rotates backup files, keeping only the most recent N backups.
Deletes oldest backups first.
"""
@spec rotate_backups(String.t(), keyword()) :: :ok
defp rotate_backups(file_path, opts) do
  max_backups = Keyword.get(opts, :max_backups, 10)

  backups = list_backups(file_path)

  # Keep space for new backup (max_backups - 1)
  to_delete =
    backups
    |> Enum.sort()
    |> Enum.drop(-(max_backups - 1))

  Enum.each(to_delete, fn backup ->
    File.rm(backup)
    emit_telemetry(:backup_rotated, %{path: backup})
  end)

  :ok
end

@doc """
Restores configuration from a specific backup file.
Creates a backup of current config before restoring.
"""
@spec restore_backup(String.t(), String.t()) :: :ok | {:error, term()}
def restore_backup(file_path, backup_path) do
  with {:ok, _current_backup} <- create_backup(file_path),
       {:ok, _} <- File.copy(backup_path, file_path) do
    emit_telemetry(:backup_restored, %{from: backup_path, to: file_path})
    ConfigVersionTracker.increment_version()
    :ok
  end
end
```

**Recovery Modal UI**:
```elixir
defmodule YellowDog.Console.SettingsLive.RecoveryModalComponent do
  use YellowDog.Console, :live_component

  alias YellowDog.Console.ConfigManager

  def render(assigns) do
    ~H"""
    <.modal id="recovery-modal" title="Configuration Recovery">
      <div class="space-y-4">
        <p class="text-sm">
          The configuration file is missing or corrupted.
          Choose a recovery option to continue:
        </p>

        <div class="form-control">
          <button
            phx-click="use_defaults"
            phx-target={@myself}
            class="btn btn-outline btn-primary"
          >
            Use Default Configuration
          </button>
          <label class="label">
            <span class="label-text-alt">Load built-in defaults</span>
          </label>
        </div>

        <%= if @has_backups do %>
          <div class="form-control">
            <button
              phx-click="show_backups"
              phx-target={@myself}
              class="btn btn-outline btn-secondary"
            >
              Restore from Backup
            </button>
            <label class="label">
              <span class="label-text-alt">
                <%= @backup_count %> backup(s) available
              </span>
            </label>
          </div>

          <%= if @show_backup_list do %>
            <div class="overflow-x-auto">
              <table class="table table-compact w-full">
                <thead>
                  <tr>
                    <th>Timestamp</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for backup <- @backups do %>
                    <tr>
                      <td><%= format_backup_timestamp(backup) %></td>
                      <td>
                        <button
                          phx-click="restore"
                          phx-value-path={backup}
                          phx-target={@myself}
                          class="btn btn-xs btn-ghost"
                        >
                          Restore
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        <% end %>

        <div class="form-control">
          <button
            phx-click="create_new"
            phx-target={@myself}
            class="btn btn-outline"
          >
            Create New Configuration
          </button>
          <label class="label">
            <span class="label-text-alt">Initialize minimal valid config</span>
          </label>
        </div>
      </div>
    </.modal>
    """
  end

  def mount(socket) do
    config_path = YellowDog.Config.config_path()
    backups = ConfigManager.list_backups(config_path)

    socket =
      socket
      |> assign(:backups, backups)
      |> assign(:backup_count, length(backups))
      |> assign(:has_backups, length(backups) > 0)
      |> assign(:show_backup_list, false)

    {:ok, socket}
  end
end
```

### Alternatives Considered

1. **Manual Backup (user-initiated)**
   - Rejected: Users forget, risk of data loss
   - Inconsistent backup frequency

2. **Time-Based Backup (every N minutes)**
   - Rejected: Creates backups even when no changes made
   - Wastes storage, clutters backup directory

3. **Git-Based Version Control**
   - Rejected: Over-engineered, requires Git repository setup
   - Adds external dependency and complexity

4. **Keep All Backups Forever**
   - Rejected: Storage accumulation over time
   - Requires manual cleanup eventually

### Key Patterns

- **Before Every Save**: Backup is first step in save operation
- **Atomic Operation**: Backup → Save → Verify as transaction
- **Rotation Before Creation**: Always rotate before creating new backup
- **ISO 8601 Timestamps**: Sortable, timezone-aware, standard format
- **Recovery UI**: Present backups in table with restore button
- **Telemetry Events**: Track backup creation, rotation, restoration

---

## Research Topic 5: Service Restart Mechanism

### Decision

Use OTP supervisor's **terminate-and-restart pattern** with configuration update via `YellowDog.Config` Agent, monitoring for successful restart with health checks.

### Rationale

1. **OTP Standard Pattern**: Leverages built-in supervision tree capabilities
2. **Safe Restart**: Supervisor ensures clean shutdown and startup
3. **Configuration Reload**: Agent update ensures new config is loaded on restart
4. **Health Verification**: Poll service status to confirm successful restart
5. **Isolation**: Per-service restart doesn't affect other services

### Implementation Pattern

**Service Restart Orchestration**:
```elixir
defmodule YellowDog.Console.ServiceManager do
  @moduledoc """
  Manages service lifecycle operations for web console.
  Provides safe restart mechanisms with configuration updates.
  """

  require Logger

  @doc """
  Applies pending configuration for a service and restarts it.

  Steps:
  1. Update configuration in YellowDog.Config Agent
  2. Get current supervisor PID for service
  3. Terminate supervisor (OTP will restart automatically)
  4. Monitor for restart completion
  5. Verify service health

  Returns :ok or {:error, reason}.
  """
  @spec apply_and_restart(atom(), map()) :: :ok | {:error, term()}
  def apply_and_restart(service, new_config) do
    with :ok <- update_config(service, new_config),
         {:ok, old_pid} <- get_supervisor_pid(service),
         :ok <- terminate_supervisor(old_pid),
         {:ok, new_pid} <- wait_for_restart(service, old_pid),
         :ok <- verify_service_health(service, new_pid) do

      emit_telemetry(:service_restarted, %{service: service})
      Logger.info("Service #{service} restarted successfully")
      :ok
    else
      {:error, reason} = error ->
        emit_telemetry(:service_restart_failed, %{service: service, reason: reason})
        Logger.error("Failed to restart service #{service}: #{inspect(reason)}")
        error
    end
  end

  defp update_config(service, new_config) do
    # Update YellowDog.Config Agent with new configuration
    YellowDog.Config.update(service, new_config)
  end

  defp get_supervisor_pid(service) do
    supervisor_name = supervisor_module(service)

    case Process.whereis(supervisor_name) do
      nil -> {:error, :supervisor_not_running}
      pid -> {:ok, pid}
    end
  end

  defp supervisor_module(:dns), do: YellowDog.Dns.Supervisor
  defp supervisor_module(:mdns), do: YellowDog.Mdns.Supervisor
  defp supervisor_module(:dhcpv4), do: YellowDog.Dhcpv4.Supervisor
  defp supervisor_module(:dhcpv6), do: YellowDog.Dhcpv6.Supervisor

  defp terminate_supervisor(pid) do
    # Monitor the process to detect termination
    ref = Process.monitor(pid)

    # Request termination via parent supervisor
    # (YellowDog.Application is parent of all service supervisors)
    Supervisor.terminate_child(YellowDog.Application, pid)

    # Wait for DOWN message (with timeout)
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5000 -> {:error, :termination_timeout}
    end
  end

  defp wait_for_restart(service, old_pid, attempt \\ 1) do
    max_attempts = 10

    if attempt > max_attempts do
      {:error, :restart_timeout}
    else
      supervisor_name = supervisor_module(service)

      case Process.whereis(supervisor_name) do
        nil ->
          # Not restarted yet, wait and retry
          Process.sleep(100 * attempt)  # Exponential backoff
          wait_for_restart(service, old_pid, attempt + 1)

        ^old_pid ->
          # Same PID? Shouldn't happen, but handle it
          Process.sleep(100 * attempt)
          wait_for_restart(service, old_pid, attempt + 1)

        new_pid ->
          {:ok, new_pid}
      end
    end
  end

  defp verify_service_health(service, pid) do
    # Give service time to initialize
    Process.sleep(500)

    # Check if supervisor is still alive
    if Process.alive?(pid) do
      # Verify children are started
      case Supervisor.count_children(pid) do
        %{active: active} when active > 0 -> :ok
        _ -> {:error, :no_active_children}
      end
    else
      {:error, :supervisor_died}
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:yellow_dog, :console, :service, event],
      %{timestamp: System.monotonic_time()},
      metadata
    )
  end
end
```

**LiveView Integration**:
```elixir
def handle_event("apply_changes", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)
  pending_config = get_in(socket.assigns.pending_changes, [service])

  unless pending_config do
    {:noreply, put_flash(socket, :error, "No pending changes for #{service}")}
  else
    # Show loading state
    socket = assign(socket, :applying_service, service)

    # Apply changes in background task
    task =
      Task.async(fn ->
        ServiceManager.apply_and_restart(service, pending_config)
      end)

    # Store task reference
    {:noreply, assign(socket, :apply_task, task)}
  end
end

def handle_info({ref, result}, socket) when socket.assigns.apply_task.ref == ref do
  # Task completed
  Process.demonitor(ref, [:flush])

  service = socket.assigns.applying_service

  socket =
    case result do
      :ok ->
        socket
        |> clear_pending_changes(service)
        |> put_flash(:info, "#{service} configuration applied successfully")
        |> assign(:applying_service, nil)

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to apply #{service} configuration: #{inspect(reason)}")
        |> assign(:applying_service, nil)
    end

  {:noreply, socket}
end
```

**Configuration Update in YellowDog.Config**:
```elixir
defmodule YellowDog.Config do
  use Agent

  # ... existing functions ...

  @doc """
  Updates configuration for a specific service.
  New config will be loaded on next service restart.
  """
  @spec update(atom(), map()) :: :ok
  def update(service, new_config) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [to_string(service)], new_config)
    end)
  end

  @doc """
  Compare-and-swap update with version checking.
  Returns :ok or {:error, :version_mismatch}.
  """
  @spec compare_and_swap(atom(), map(), non_neg_integer()) ::
    :ok | {:error, :version_mismatch}
  def compare_and_swap(service, new_config, expected_version) do
    Agent.get_and_update(__MODULE__, fn state ->
      current_version = Map.get(state, :_version, 0)

      if current_version == expected_version do
        new_state =
          state
          |> put_in([to_string(service)], new_config)
          |> Map.put(:_version, current_version + 1)

        {:ok, new_state}
      else
        {{:error, :version_mismatch}, state}
      end
    end)
  end
end
```

### Alternatives Considered

1. **Direct Process Termination (Process.exit/2)**
   - Rejected: Bypasses supervisor, no automatic restart
   - Requires manual restart logic

2. **Hot Code Reload (Code.reload_module/1)**
   - Rejected: Doesn't restart GenServers or reload configuration
   - Only reloads module code, not runtime state

3. **Application Restart (Application.stop + Application.start)**
   - Rejected: Restarts entire Yellow Dog application
   - Affects all services, not just the one being configured

4. **Dynamic Supervisor with delete_child + start_child**
   - Rejected: Requires changing supervision strategy
   - More complex than leveraging existing one_for_one supervisor

### Key Patterns

- **Monitor Pattern**: Monitor old PID to detect termination completion
- **Exponential Backoff**: Increase wait time between restart polls
- **Health Verification**: Check supervisor is alive AND has active children
- **Async Task**: Run restart in background to avoid blocking LiveView
- **Loading State**: Show spinner/indicator during restart operation
- **Rollback Option**: Keep previous config in case restart fails

---

## Summary of Decisions

| Topic | Decision | Key Technology |
|-------|----------|----------------|
| **Form Validation** | Ecto embedded schemas + phx-change events | Ecto.Changeset, DaisyUI error states |
| **TOML Preservation** | Line-based partial update with token parsing | Custom parser, atomic file writes |
| **Optimistic Locking** | Hybrid version counter + file timestamp | ETS, Agent, File.stat |
| **Backup Strategy** | Before-every-save with 10-backup rotation | Timestamped files, automatic rotation |
| **Service Restart** | OTP terminate-and-restart via supervisor | Supervisor.terminate_child, Process.monitor |

---

## Phase 0 Complete

All research topics have been resolved with concrete technical decisions. The implementation plan in [plan.md](./plan.md) can now proceed to **Phase 1: Design Artifacts** generation.

**Next Steps**:
1. Generate `data-model.md` with entity schemas
2. Generate `contracts/settings-api.md` with LiveView message contracts
3. Generate `quickstart.md` with developer setup guide
4. Execute Phase 2 task generation via `/speckit.tasks`
