# LiveView Message Contracts: Console Settings Management

**Feature**: Console Settings Management (001-console-settings)
**Date**: 2025-11-10
**Phase**: Phase 1 - Design Artifacts
**Plan**: [plan.md](../plan.md)

## Overview

This document defines the Phoenix LiveView message contracts for the Console Settings Management feature. All messages follow LiveView event conventions using `handle_event/3` pattern.

---

## Settings Page Events

### `load_configuration`

**Purpose**: Load configuration from TOML file on initial page mount

**Direction**: Server → Internal (called during `mount/3`)

**Parameters**: None (uses config path from `YellowDog.Config`)

**Response**:
```elixir
{:ok,
  assign(socket,
    config: %{
      dns: %ServiceConfiguration{...},
      mdns: %ServiceConfiguration{...},
      dhcpv4: %ServiceConfiguration{...},
      dhcpv6: %ServiceConfiguration{...}
    },
    config_version: 10,
    config_timestamp: 1699627800,
    pending_changes: %{},
    active_tab: :dns
  )
}
```

**Error Handling**:
- File missing → Trigger recovery modal
- File corrupted → Trigger recovery modal
- Permission denied → Display error flash

**Implementation**:
```elixir
def mount(_params, _session, socket) do
  config_path = YellowDog.Config.config_path()

  case ConfigManager.load_config(config_path) do
    {:ok, config} ->
      version_info = ConfigVersionTracker.get_version(config_path)

      socket =
        socket
        |> assign(:config, config)
        |> assign(:config_version, version_info.version)
        |> assign(:config_timestamp, version_info.timestamp)
        |> assign(:pending_changes, %{})
        |> assign(:active_tab, :dns)
        |> assign(:show_recovery_modal, false)

      {:ok, socket}

    {:error, :file_not_found} ->
      socket =
        socket
        |> assign(:show_recovery_modal, true)
        |> assign(:recovery_reason, :file_not_found)

      {:ok, socket}

    {:error, :invalid_toml} ->
      socket =
        socket
        |> assign(:show_recovery_modal, true)
        |> assign(:recovery_reason, :corrupted)

      {:ok, socket}
  end
end
```

---

### `switch_tab`

**Purpose**: Navigate between service configuration tabs

**Direction**: Client → Server

**Parameters**:
```elixir
%{"tab" => "dns" | "mdns" | "dhcpv4" | "dhcpv6"}
```

**Response**:
```elixir
{:noreply, assign(socket, :active_tab, :dns)}
```

**Side Effects**:
- Updates `:active_tab` assign
- Triggers re-render of tab content
- No configuration changes

**Implementation**:
```elixir
def handle_event("switch_tab", %{"tab" => tab_str}, socket) do
  tab = String.to_existing_atom(tab_str)

  if tab in [:dns, :mdns, :dhcpv4, :dhcpv6] do
    {:noreply, assign(socket, :active_tab, tab)}
  else
    {:noreply, put_flash(socket, :error, "Invalid tab: #{tab_str}")}
  end
end
```

**Template Usage**:
```heex
<div class="tabs tabs-boxed">
  <button
    phx-click="switch_tab"
    phx-value-tab="dns"
    class={["tab", @active_tab == :dns && "tab-active"]}
  >
    DNS
    <%= if has_pending_changes?(@pending_changes, :dns) do %>
      <.badge color="warning" size="sm">Pending</.badge>
    <% end %>
  </button>
  <!-- Repeat for mdns, dhcpv4, dhcpv6 -->
</div>
```

---

### `validate_field`

**Purpose**: Real-time validation of form fields as user types

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "service" => "dns",
  "field" => "port",
  "value" => "5353"
}
```

**Response**:
```elixir
{:noreply,
  assign(socket, :changeset,
    ServiceConfiguration.changeset(config, %{port: 5353})
    |> Map.put(:action, :validate)
  )
}
```

**Validation**:
- Field-level validation using Ecto changeset
- Returns updated changeset with errors
- Does not save to file

**Implementation**:
```elixir
def handle_event("validate_field", %{"service" => service, "field" => field, "value" => value}, socket) do
  service_atom = String.to_existing_atom(service)
  field_atom = String.to_existing_atom(field)

  current_config = get_in(socket.assigns.config, [service_atom])

  changeset =
    current_config
    |> ServiceConfiguration.changeset(%{field_atom => value})
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, :changeset, changeset)}
end
```

**Template Usage**:
```heex
<.input
  field={@changeset[:port]}
  type="number"
  phx-change="validate_field"
  phx-debounce="300"
  class={["input input-bordered", @changeset.errors[:port] && "input-error"]}
/>
```

---

### `save_configuration`

**Purpose**: Save pending configuration changes to TOML file

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "service" => "dns",
  "config" => %{
    "enabled" => true,
    "listen" => "0.0.0.0",
    "port" => 5353
  }
}
```

**Response Success**:
```elixir
{:noreply,
  socket
  |> assign(:config_version, new_version)
  |> assign(:config_timestamp, new_timestamp)
  |> update(:pending_changes, &Map.put(&1, :dns, new_config))
  |> put_flash(:info, "DNS configuration saved successfully")
}
```

**Response Error (Version Mismatch)**:
```elixir
{:noreply,
  socket
  |> assign(:show_conflict_modal, true)
  |> assign(:conflict_reason, :version_mismatch)
  |> put_flash(:error, "Configuration was modified by another administrator")
}
```

**Response Error (File Modified)**:
```elixir
{:noreply,
  socket
  |> assign(:show_conflict_modal, true)
  |> assign(:conflict_reason, :file_modified)
  |> put_flash(:error, "Configuration file was modified externally")
}
```

**Implementation**:
```elixir
def handle_event("save_configuration", %{"service" => service_str, "config" => params}, socket) do
  service = String.to_existing_atom(service_str)
  config_path = YellowDog.Config.config_path()

  # Validate configuration
  changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, params)

  if changeset.valid? do
    # Check optimistic lock
    case ConfigVersionTracker.compare_and_swap(
      config_path,
      socket.assigns.config_version,
      socket.assigns.config_timestamp
    ) do
      :ok ->
        # Build TOML updates
        updates = build_toml_updates(service, params)

        # Save to file with backup
        case ConfigManager.save_config(config_path, updates, backup: true) do
          :ok ->
            # Refresh version tracking
            version_info = ConfigVersionTracker.get_version(config_path)
            new_config = Ecto.Changeset.apply_changes(changeset)

            socket =
              socket
              |> assign(:config_version, version_info.version)
              |> assign(:config_timestamp, version_info.timestamp)
              |> update(:pending_changes, &Map.put(&1, service, new_config))
              |> put_flash(:info, "#{service} configuration saved successfully")

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, :version_mismatch} ->
        handle_conflict(socket, :version_mismatch)

      {:error, :file_modified} ->
        handle_conflict(socket, :file_modified)
    end
  else
    socket =
      socket
      |> assign(:changeset, changeset)
      |> put_flash(:error, "Validation failed. Please correct the errors.")

    {:noreply, socket}
  end
end
```

---

### `apply_changes`

**Purpose**: Activate pending configuration and restart service

**Direction**: Client → Server

**Parameters**:
```elixir
%{"service" => "dns"}
```

**Response Success**:
```elixir
{:noreply,
  socket
  |> update(:pending_changes, &Map.put(&1, :dns, nil))
  |> put_flash(:info, "DNS service restarted with new configuration")
}
```

**Response Error**:
```elixir
{:noreply,
  put_flash(socket, :error, "Failed to restart DNS service: supervisor timeout")
}
```

**Implementation**:
```elixir
def handle_event("apply_changes", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)
  pending_config = get_in(socket.assigns.pending_changes, [service])

  unless pending_config do
    {:noreply, put_flash(socket, :error, "No pending changes for #{service}")}
  else
    # Show loading state
    socket = assign(socket, :applying_service, service)

    # Apply changes asynchronously
    task =
      Task.async(fn ->
        ServiceManager.apply_and_restart(service, pending_config)
      end)

    {:noreply, assign(socket, :apply_task, task)}
  end
end

# Handle async task completion
def handle_info({ref, result}, socket) when socket.assigns.apply_task.ref == ref do
  Process.demonitor(ref, [:flush])

  service = socket.assigns.applying_service

  socket =
    case result do
      :ok ->
        socket
        |> update(:pending_changes, &Map.put(&1, service, nil))
        |> assign(:applying_service, nil)
        |> put_flash(:info, "#{service} configuration applied successfully")

      {:error, reason} ->
        socket
        |> assign(:applying_service, nil)
        |> put_flash(:error, "Failed to apply #{service} configuration: #{inspect(reason)}")
    end

  {:noreply, socket}
end
```

**Template Usage**:
```heex
<%= if has_pending_changes?(@pending_changes, :dns) do %>
  <button
    phx-click="apply_changes"
    phx-value-service="dns"
    class="btn btn-success"
    disabled={@applying_service == :dns}
  >
    <%= if @applying_service == :dns do %>
      <.loading size="sm" /> Applying...
    <% else %>
      Apply Changes
    <% end %>
  </button>
<% end %>
```

---

### `reload_configuration`

**Purpose**: Reload configuration from file (conflict resolution)

**Direction**: Client → Server

**Parameters**:
```elixir
%{"discard_pending" => true | false}
```

**Response**:
```elixir
{:noreply,
  socket
  |> assign(:config, reloaded_config)
  |> assign(:config_version, new_version)
  |> assign(:config_timestamp, new_timestamp)
  |> assign(:pending_changes, %{})  # If discard_pending: true
  |> assign(:show_conflict_modal, false)
  |> put_flash(:info, "Configuration reloaded from file")
}
```

**Implementation**:
```elixir
def handle_event("reload_configuration", %{"discard_pending" => discard_str}, socket) do
  discard_pending = discard_str == "true"
  config_path = YellowDog.Config.config_path()

  case ConfigManager.load_config(config_path) do
    {:ok, config} ->
      version_info = ConfigVersionTracker.get_version(config_path)

      socket =
        socket
        |> assign(:config, config)
        |> assign(:config_version, version_info.version)
        |> assign(:config_timestamp, version_info.timestamp)
        |> assign(:show_conflict_modal, false)

      socket =
        if discard_pending do
          socket |> assign(:pending_changes, %{})
        else
          socket
        end

      socket = put_flash(socket, :info, "Configuration reloaded successfully")

      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Reload failed: #{inspect(reason)}")}
  end
end
```

---

### `recover_configuration`

**Purpose**: Handle missing/corrupt configuration file recovery

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "action" => "use_defaults" | "restore_backup" | "create_new",
  "backup_path" => "config.toml.backup.20251110T143052Z"  # If restore_backup
}
```

**Response Success**:
```elixir
{:noreply,
  socket
  |> assign(:config, recovered_config)
  |> assign(:show_recovery_modal, false)
  |> put_flash(:info, "Configuration recovered successfully")
}
```

**Implementation**:
```elixir
def handle_event("recover_configuration", %{"action" => action} = params, socket) do
  config_path = YellowDog.Config.config_path()

  result =
    case action do
      "use_defaults" ->
        ConfigManager.create_default_config(config_path)

      "restore_backup" ->
        backup_path = params["backup_path"]
        ConfigManager.restore_backup(config_path, backup_path)

      "create_new" ->
        ConfigManager.create_minimal_config(config_path)
    end

  case result do
    :ok ->
      {:ok, config} = ConfigManager.load_config(config_path)
      version_info = ConfigVersionTracker.get_version(config_path)

      socket =
        socket
        |> assign(:config, config)
        |> assign(:config_version, version_info.version)
        |> assign(:config_timestamp, version_info.timestamp)
        |> assign(:show_recovery_modal, false)
        |> put_flash(:info, "Configuration recovered successfully")

      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Recovery failed: #{inspect(reason)}")}
  end
end
```

---

## Pool Management Events

### `add_pool`

**Purpose**: Open modal to create new address pool

**Direction**: Client → Server

**Parameters**:
```elixir
%{"service" => "dhcpv4" | "dhcpv6"}
```

**Response**:
```elixir
{:noreply,
  socket
  |> assign(:show_pool_form, true)
  |> assign(:pool_form_mode, :create)
  |> assign(:pool_service, :dhcpv4)
  |> assign(:pool_changeset, AddressPool.changeset(%AddressPool{}, %{}))
}
```

**Implementation**:
```elixir
def handle_event("add_pool", %{"service" => service_str}, socket) do
  service = String.to_existing_atom(service_str)
  protocol = if service == :dhcpv4, do: :ipv4, else: :ipv6

  changeset = AddressPool.changeset(%AddressPool{protocol: protocol}, %{})

  socket =
    socket
    |> assign(:show_pool_form, true)
    |> assign(:pool_form_mode, :create)
    |> assign(:pool_service, service)
    |> assign(:pool_changeset, changeset)

  {:noreply, socket}
end
```

---

### `edit_pool`

**Purpose**: Open modal to edit existing address pool

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "service" => "dhcpv4",
  "pool_id" => "pool-uuid-123"
}
```

**Response**:
```elixir
{:noreply,
  socket
  |> assign(:show_pool_form, true)
  |> assign(:pool_form_mode, :edit)
  |> assign(:pool_service, :dhcpv4)
  |> assign(:editing_pool_id, "pool-uuid-123")
  |> assign(:pool_changeset, AddressPool.changeset(pool, %{}))
}
```

**Implementation**:
```elixir
def handle_event("edit_pool", %{"service" => service_str, "pool_id" => pool_id}, socket) do
  service = String.to_existing_atom(service_str)
  config = get_in(socket.assigns.config, [service])

  pool = Enum.find(config.pools, fn p -> p.id == pool_id end)

  unless pool do
    {:noreply, put_flash(socket, :error, "Pool not found")}
  else
    changeset = AddressPool.changeset(pool, %{})

    socket =
      socket
      |> assign(:show_pool_form, true)
      |> assign(:pool_form_mode, :edit)
      |> assign(:pool_service, service)
      |> assign(:editing_pool_id, pool_id)
      |> assign(:pool_changeset, changeset)

    {:noreply, socket}
  end
end
```

---

### `delete_pool`

**Purpose**: Delete address pool with confirmation

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "service" => "dhcpv4",
  "pool_id" => "pool-uuid-123",
  "confirmed" => true | false
}
```

**Response (Show Confirmation)**:
```elixir
{:noreply,
  socket
  |> assign(:show_delete_confirmation, true)
  |> assign(:deleting_pool_id, "pool-uuid-123")
  |> assign(:deleting_pool_service, :dhcpv4)
}
```

**Response (Confirmed Delete)**:
```elixir
{:noreply,
  socket
  |> update_in([:config, :dhcpv4, :pools], fn pools ->
    Enum.reject(pools, &(&1.id == "pool-uuid-123"))
  end)
  |> assign(:show_delete_confirmation, false)
  |> put_flash(:info, "Pool deleted successfully")
}
```

**Implementation**:
```elixir
def handle_event("delete_pool", %{"service" => service_str, "pool_id" => pool_id, "confirmed" => confirmed_str}, socket) do
  service = String.to_existing_atom(service_str)
  confirmed = confirmed_str == "true"

  if confirmed do
    # Delete pool from configuration
    socket =
      socket
      |> update_in([:config, service, :pools], fn pools ->
        Enum.reject(pools, &(&1.id == pool_id))
      end)
      |> assign(:show_delete_confirmation, false)
      |> put_flash(:info, "Pool deleted. Click 'Save' to persist changes.")

    {:noreply, socket}
  else
    # Show confirmation modal
    socket =
      socket
      |> assign(:show_delete_confirmation, true)
      |> assign(:deleting_pool_id, pool_id)
      |> assign(:deleting_pool_service, service)

    {:noreply, socket}
  end
end
```

---

### `validate_pool`

**Purpose**: Real-time validation of pool form fields

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "pool" => %{
    "name" => "Office Network",
    "range_start" => "192.168.1.100",
    "range_end" => "192.168.1.200",
    "lease_time" => "3600"
  }
}
```

**Response**:
```elixir
{:noreply,
  assign(socket, :pool_changeset,
    AddressPool.changeset(%AddressPool{protocol: :ipv4}, params)
    |> Map.put(:action, :validate)
  )
}
```

**Implementation**:
```elixir
def handle_event("validate_pool", %{"pool" => params}, socket) do
  protocol = if socket.assigns.pool_service == :dhcpv4, do: :ipv4, else: :ipv6

  changeset =
    %AddressPool{protocol: protocol}
    |> AddressPool.changeset(params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, :pool_changeset, changeset)}
end
```

---

### `save_pool`

**Purpose**: Save new or edited address pool

**Direction**: Client → Server

**Parameters**:
```elixir
%{
  "pool" => %{
    "name" => "Office Network",
    "range_start" => "192.168.1.100",
    "range_end" => "192.168.1.200",
    "lease_time" => "3600",
    "gateway" => "192.168.1.1",
    "dns_servers" => ["8.8.8.8", "8.8.4.4"]
  }
}
```

**Response Success (Create)**:
```elixir
{:noreply,
  socket
  |> update_in([:config, :dhcpv4, :pools], &[new_pool | &1])
  |> assign(:show_pool_form, false)
  |> put_flash(:info, "Pool created. Click 'Save' to persist changes.")
}
```

**Response Success (Edit)**:
```elixir
{:noreply,
  socket
  |> update_in([:config, :dhcpv4, :pools], fn pools ->
    Enum.map(pools, fn pool ->
      if pool.id == editing_pool_id, do: updated_pool, else: pool
    end)
  end)
  |> assign(:show_pool_form, false)
  |> put_flash(:info, "Pool updated. Click 'Save' to persist changes.")
}
```

**Implementation**:
```elixir
def handle_event("save_pool", %{"pool" => params}, socket) do
  protocol = if socket.assigns.pool_service == :dhcpv4, do: :ipv4, else: :ipv6
  changeset = AddressPool.changeset(%AddressPool{protocol: protocol}, params)

  if changeset.valid? do
    new_pool = Ecto.Changeset.apply_changes(changeset)

    socket =
      case socket.assigns.pool_form_mode do
        :create ->
          # Add UUID if not present
          pool_with_id = Map.put_new(new_pool, :id, UUID.uuid4())

          socket
          |> update_in([:config, socket.assigns.pool_service, :pools], &[pool_with_id | &1])
          |> put_flash(:info, "Pool created. Click 'Save' to persist changes.")

        :edit ->
          socket
          |> update_in([:config, socket.assigns.pool_service, :pools], fn pools ->
            Enum.map(pools, fn pool ->
              if pool.id == socket.assigns.editing_pool_id, do: new_pool, else: pool
            end)
          end)
          |> put_flash(:info, "Pool updated. Click 'Save' to persist changes.")
      end

    socket = assign(socket, :show_pool_form, false)

    {:noreply, socket}
  else
    changeset = Map.put(changeset, :action, :validate)
    {:noreply, assign(socket, :pool_changeset, changeset)}
  end
end
```

---

## Summary

**Total Events**: 12 events across 3 categories

**Categories**:
1. **Settings Page Events** (6): load, switch_tab, validate_field, save, apply, reload, recover
2. **Pool Management Events** (5): add, edit, delete, validate, save
3. **Internal Events** (1): async task completion

**Key Patterns**:
- All events return `{:noreply, socket}` with updated assigns
- Validation uses Ecto changesets with `:action` field
- Optimistic locking via `compare_and_swap`
- Async operations use Task.async with handle_info callback
- Error handling via flash messages
- Modal state managed via socket assigns

**Socket Assigns**:
- `:config` - Current configuration map
- `:config_version` - Optimistic lock version
- `:config_timestamp` - File modification timestamp
- `:pending_changes` - Per-service pending configs
- `:active_tab` - Currently displayed tab
- `:changeset` - Form validation changeset
- `:show_pool_form` - Pool modal visibility
- `:show_conflict_modal` - Conflict resolution modal
- `:show_recovery_modal` - Recovery options modal
- `:applying_service` - Service currently being restarted
