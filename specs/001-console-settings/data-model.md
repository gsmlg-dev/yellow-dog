# Data Model: Console Settings Management

**Feature**: Console Settings Management (001-console-settings)
**Date**: 2025-11-10
**Phase**: Phase 1 - Design Artifacts
**Plan**: [plan.md](./plan.md)

## Overview

This document defines the data model for the Console Settings Management feature. The model uses Ecto embedded schemas for validation and structure without requiring a database, aligning with the TOML-based configuration storage approach.

---

## Entities

### 1. ServiceConfiguration

Represents configuration for a single service (DNS, mDNS, DHCPv4, DHCPv6).

**Ecto Schema**:
```elixir
defmodule YellowDog.Console.Settings.ServiceConfiguration do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: true
    field :listen, :string
    field :port, :integer
    field :service_type, Ecto.Enum, values: [:dns, :mdns, :dhcpv4, :dhcpv6]

    # Service-specific fields
    field :mode, Ecto.Enum, values: [:responder, :hybrid], virtual: true  # mDNS only
    field :domain, :string, virtual: true  # DHCP services
    field :dns_servers, {:array, :string}, virtual: true, default: []  # DHCP services
    field :gateway, :string, virtual: true  # DHCPv4 only

    # Pool references (DHCP services only)
    embeds_many :pools, YellowDog.Console.Settings.AddressPool
  end

  @doc """
  Creates changeset for service configuration with validation.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:enabled, :listen, :port, :service_type, :mode, :domain, :dns_servers, :gateway])
    |> validate_required([:enabled, :listen, :port, :service_type])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)
    |> validate_ip_address(:listen)
    |> validate_service_specific()
    |> cast_embed(:pools, with: &AddressPool.changeset/2)
  end

  defp validate_service_specific(changeset) do
    service_type = get_field(changeset, :service_type)

    case service_type do
      :mdns ->
        changeset
        |> validate_required([:mode])
        |> validate_inclusion(:mode, [:responder, :hybrid])

      service when service in [:dhcpv4, :dhcpv6] ->
        changeset
        |> validate_pools()

      _ ->
        changeset
    end
  end

  defp validate_pools(changeset) do
    pools = get_field(changeset, :pools) || []

    if Enum.empty?(pools) do
      add_error(changeset, :pools, "must have at least one address pool")
    else
      changeset
    end
  end

  defp validate_ip_address(changeset, field) do
    validate_change(changeset, field, fn _field, address ->
      case :inet.parse_address(to_charlist(address)) do
        {:ok, _} -> []
        {:error, _} -> [{field, "must be a valid IP address"}]
      end
    end)
  end
end
```

**Attributes**:
- `enabled` (boolean): Whether service is enabled
- `listen` (string): IP address to listen on (e.g., "0.0.0.0", "::")
- `port` (integer): Port number (1-65535)
- `service_type` (enum): One of :dns, :mdns, :dhcpv4, :dhcpv6
- `mode` (enum, virtual): mDNS mode - :responder or :hybrid
- `domain` (string, virtual): Domain name for DHCP services
- `dns_servers` (array of strings, virtual): DNS server addresses for DHCP
- `gateway` (string, virtual): Gateway address for DHCPv4
- `pools` (embedded array): AddressPool entities for DHCP services

**Validation Rules**:
- `enabled`, `listen`, `port`, `service_type` are required
- `port` must be 1-65535
- `listen` must be valid IPv4 or IPv6 address
- mDNS services require `mode` field
- DHCP services must have at least one pool

**State Tracking**:
- No database persistence (uses TOML files)
- Changeset tracks pending changes in LiveView assigns
- Validation errors stored in changeset struct

---

### 2. AddressPool

Represents an IP address pool for DHCP services (DHCPv4 or DHCPv6).

**Ecto Schema**:
```elixir
defmodule YellowDog.Console.Settings.AddressPool do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :id, :string  # UUID for client-side identification
    field :name, :string
    field :range_start, :string
    field :range_end, :string
    field :lease_time, :integer  # DHCPv4: seconds
    field :preferred_lifetime, :integer  # DHCPv6: seconds
    field :valid_lifetime, :integer  # DHCPv6: seconds
    field :gateway, :string  # DHCPv4 only
    field :dns_servers, {:array, :string}, default: []
    field :protocol, Ecto.Enum, values: [:ipv4, :ipv6]
  end

  @doc """
  Creates changeset for address pool with validation.
  """
  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:id, :name, :range_start, :range_end, :lease_time,
                    :preferred_lifetime, :valid_lifetime, :gateway, :dns_servers, :protocol])
    |> validate_required([:name, :range_start, :range_end, :protocol])
    |> validate_protocol_specific()
    |> validate_range()
    |> validate_dns_servers()
  end

  defp validate_protocol_specific(changeset) do
    protocol = get_field(changeset, :protocol)

    case protocol do
      :ipv4 ->
        changeset
        |> validate_required([:lease_time])
        |> validate_number(:lease_time, greater_than: 60)
        |> validate_ipv4_addresses()

      :ipv6 ->
        changeset
        |> validate_required([:preferred_lifetime, :valid_lifetime])
        |> validate_number(:preferred_lifetime, greater_than: 60)
        |> validate_number(:valid_lifetime, greater_than: 60)
        |> validate_ipv6_addresses()
        |> validate_lifetime_relationship()

      _ ->
        add_error(changeset, :protocol, "must be ipv4 or ipv6")
    end
  end

  defp validate_range(changeset) do
    range_start = get_field(changeset, :range_start)
    range_end = get_field(changeset, :range_end)
    protocol = get_field(changeset, :protocol)

    if range_start && range_end && protocol do
      case YellowDog.Console.Validators.validate_pool_range(range_start, range_end, protocol) do
        :ok -> changeset
        {:error, message} -> add_error(changeset, :range_start, message)
      end
    else
      changeset
    end
  end

  defp validate_ipv4_addresses(changeset) do
    changeset
    |> validate_ip_format(:range_start, :ipv4)
    |> validate_ip_format(:range_end, :ipv4)
    |> validate_ip_format(:gateway, :ipv4)
  end

  defp validate_ipv6_addresses(changeset) do
    changeset
    |> validate_ip_format(:range_start, :ipv6)
    |> validate_ip_format(:range_end, :ipv6)
  end

  defp validate_ip_format(changeset, field, protocol) do
    validate_change(changeset, field, fn _field, address ->
      if is_nil(address) do
        []
      else
        case YellowDog.Console.Validators.validate_ip(address, protocol) do
          :ok -> []
          {:error, message} -> [{field, message}]
        end
      end
    end)
  end

  defp validate_dns_servers(changeset) do
    dns_servers = get_field(changeset, :dns_servers) || []
    protocol = get_field(changeset, :protocol)

    invalid_servers =
      dns_servers
      |> Enum.filter(fn server ->
        case YellowDog.Console.Validators.validate_ip(server, protocol) do
          :ok -> false
          {:error, _} -> true
        end
      end)

    if Enum.empty?(invalid_servers) do
      changeset
    else
      add_error(changeset, :dns_servers, "contains invalid IP addresses: #{inspect(invalid_servers)}")
    end
  end

  defp validate_lifetime_relationship(changeset) do
    preferred = get_field(changeset, :preferred_lifetime)
    valid = get_field(changeset, :valid_lifetime)

    if preferred && valid && preferred > valid do
      add_error(changeset, :preferred_lifetime, "must be less than or equal to valid lifetime")
    else
      changeset
    end
  end
end
```

**Attributes**:
- `id` (string): UUID for client-side pool identification
- `name` (string): Pool name (must be unique within service)
- `range_start` (string): Starting IP address of range
- `range_end` (string): Ending IP address of range
- `lease_time` (integer): DHCPv4 lease duration in seconds
- `preferred_lifetime` (integer): DHCPv6 preferred lifetime in seconds
- `valid_lifetime` (integer): DHCPv6 valid lifetime in seconds
- `gateway` (string): Gateway address (DHCPv4 only)
- `dns_servers` (array of strings): DNS server addresses
- `protocol` (enum): :ipv4 or :ipv6

**Validation Rules**:
- `name`, `range_start`, `range_end`, `protocol` are required
- DHCPv4 pools require `lease_time` >= 60 seconds
- DHCPv6 pools require `preferred_lifetime` and `valid_lifetime` >= 60 seconds
- DHCPv6: `preferred_lifetime` <= `valid_lifetime`
- IP addresses must match protocol (IPv4 for :ipv4, IPv6 for :ipv6)
- Range start must be less than range end (numeric comparison)
- DNS servers must be valid IP addresses matching protocol
- Pool names must be unique within service (validated at ServiceConfiguration level)

**Relationships**:
- Embedded in `ServiceConfiguration` via `embeds_many :pools`
- No database persistence (stored in TOML configuration)

---

### 3. ConfigurationVersion

Tracks configuration file versions for optimistic locking.

**Implementation**: ETS table + Agent (not Ecto schema)

**Structure**:
```elixir
defmodule YellowDog.Console.Settings.ConfigurationVersion do
  @moduledoc """
  Tracks configuration versions for optimistic locking.
  Uses ETS for storage and Agent for atomic operations.
  """

  use Agent

  @table_name :config_versions

  def start_link(_opts) do
    Agent.start_link(fn ->
      :ets.new(@table_name, [:set, :public, :named_table])
      %{current_version: 0}
    end, name: __MODULE__)
  end

  @type version_info :: %{
    version: non_neg_integer(),
    timestamp: integer(),
    file_path: String.t()
  }

  @spec get_version(String.t()) :: version_info()
  def get_version(file_path) do
    version = Agent.get(__MODULE__, fn state -> state.current_version end)
    timestamp = get_file_timestamp(file_path)

    %{
      version: version,
      timestamp: timestamp,
      file_path: file_path
    }
  end

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

  @spec increment_version() :: :ok
  def increment_version do
    Agent.update(__MODULE__, fn state ->
      %{state | current_version: state.current_version + 1}
    end)
  end

  defp get_file_timestamp(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix()

      {:error, _} ->
        0
    end
  end
end
```

**Attributes**:
- `version` (integer): Monotonically increasing version counter
- `timestamp` (integer): Unix timestamp of file modification
- `file_path` (string): Path to configuration file

**Operations**:
- `get_version/1`: Get current version and timestamp for file
- `compare_and_swap/3`: Atomic version check and increment
- `increment_version/0`: Force version increment (after external modification)

**Usage Pattern**:
```elixir
# On page load
version_info = ConfigurationVersion.get_version(config_path)
socket = assign(socket, :config_version, version_info.version)
socket = assign(socket, :config_timestamp, version_info.timestamp)

# On save
case ConfigurationVersion.compare_and_swap(
  config_path,
  socket.assigns.config_version,
  socket.assigns.config_timestamp
) do
  :ok -> # Proceed with save
  {:error, :version_mismatch} -> # Show conflict modal
  {:error, :file_modified} -> # Show file modified modal
end
```

---

### 4. PendingChange

Represents staged configuration changes awaiting application.

**Implementation**: Map structure in LiveView assigns (not persisted)

**Structure**:
```elixir
%{
  dns: %ServiceConfiguration{
    # New configuration values
  },
  mdns: nil,  # No pending changes
  dhcpv4: %ServiceConfiguration{
    pools: [
      %AddressPool{id: "pool-1", ...},  # Modified pool
      %AddressPool{id: "pool-new", ...}  # New pool
    ]
  },
  dhcpv6: nil
}
```

**Attributes**:
- Key: Service name (`:dns`, `:mdns`, `:dhcpv4`, `:dhcpv6`)
- Value: `ServiceConfiguration` struct or `nil` (no pending changes)

**State Management**:
```elixir
# Check if service has pending changes
def has_pending_changes?(socket, service) do
  not is_nil(get_in(socket.assigns.pending_changes, [service]))
end

# Get pending configuration for service
def get_pending_config(socket, service) do
  get_in(socket.assigns.pending_changes, [service])
end

# Set pending changes for service
def set_pending_changes(socket, service, config) do
  update_in(socket.assigns.pending_changes, &Map.put(&1, service, config))
end

# Clear pending changes after apply
def clear_pending_changes(socket, service) do
  update_in(socket.assigns.pending_changes, &Map.put(&1, service, nil))
end
```

**UI Indicators**:
- Badge on tab showing "Pending" status
- "Apply Changes" button enabled when pending changes exist
- Diff view showing current vs. pending configuration

---

## Data Flow Diagrams

### Configuration Load Flow

```
User navigates to /settings
  ↓
SettingsLive.mount/3
  ↓
ConfigManager.load_config(config_path)
  ↓ (read TOML file)
Toml.decode_file(config_path)
  ↓ (parse into map)
Build ServiceConfiguration structs for each service
  ↓
ConfigurationVersion.get_version(config_path)
  ↓ (get version + timestamp)
Assign to socket:
  - @config (map of ServiceConfiguration)
  - @config_version (integer)
  - @config_timestamp (integer)
  - @pending_changes (%{})
  - @active_tab (:dns)
```

### Configuration Save Flow

```
User clicks "Save" button
  ↓
SettingsLive.handle_event("save", params, socket)
  ↓
Validate changeset for service
  ↓ (validation passes)
ConfigurationVersion.compare_and_swap(path, version, timestamp)
  ↓ (version matches)
ConfigManager.save_config(path, updates, backup: true)
  ↓
Create backup: config.toml.backup.20251110T143052Z
  ↓
Apply line-based updates to TOML file
  ↓
Atomic write: config.toml.tmp → config.toml
  ↓
Verify: Toml.decode_file(config.toml)
  ↓
Update PendingChange: assign pending_changes[service] = new_config
  ↓
Refresh version: get_version(path)
  ↓
Display success toast: "Configuration saved"
```

### Configuration Apply Flow

```
User clicks "Apply Changes" button
  ↓
SettingsLive.handle_event("apply_changes", %{service: service}, socket)
  ↓
Get pending config from socket.assigns.pending_changes[service]
  ↓
ServiceManager.apply_and_restart(service, pending_config)
  ↓
YellowDog.Config.update(service, pending_config)
  ↓ (update Agent state)
Get supervisor PID for service
  ↓
Supervisor.terminate_child(YellowDog.Application, supervisor_pid)
  ↓
Monitor process for termination (Process.monitor)
  ↓ (supervisor restarts automatically)
Wait for new supervisor PID
  ↓
Verify service health: Supervisor.count_children(new_pid)
  ↓ (health check passes)
Clear pending changes: assign pending_changes[service] = nil
  ↓
Display success toast: "Service restarted successfully"
```

### Conflict Detection Flow

```
Administrator A loads /settings at 14:30:00
  version: 10, timestamp: 1699627800

Administrator B loads /settings at 14:30:05
  version: 10, timestamp: 1699627800

Administrator A saves DNS config at 14:31:00
  ↓
  compare_and_swap(10, 1699627800)
  ↓ (matches)
  version incremented to 11
  file timestamp: 1699627860
  ↓ SUCCESS

Administrator B saves DNS config at 14:31:30
  ↓
  compare_and_swap(10, 1699627800)
  ↓ (version mismatch: 10 != 11)
  {:error, :version_mismatch}
  ↓
  Display conflict modal:
  "Configuration was modified by another administrator.
   Please reload the page to see the latest changes."
```

---

## Validation Module

**YellowDog.Console.Validators**:
```elixir
defmodule YellowDog.Console.Validators do
  @moduledoc """
  Validation functions for configuration values.
  Provides reusable validators for IP addresses, ports, ranges, etc.
  """

  @spec validate_ip(String.t(), :ipv4 | :ipv6) :: :ok | {:error, String.t()}
  def validate_ip(address, protocol) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, {_, _, _, _}} when protocol == :ipv4 ->
        :ok

      {:ok, {_, _, _, _, _, _, _, _}} when protocol == :ipv6 ->
        :ok

      {:ok, _} ->
        {:error, "IP address does not match protocol #{protocol}"}

      {:error, :einval} ->
        {:error, "Invalid IP address format"}
    end
  end

  @spec validate_port(integer()) :: :ok | {:error, String.t()}
  def validate_port(port) when is_integer(port) do
    if port >= 1 and port <= 65535 do
      :ok
    else
      {:error, "Port must be between 1 and 65535"}
    end
  end

  @spec validate_pool_range(String.t(), String.t(), :ipv4 | :ipv6) ::
    :ok | {:error, String.t()}
  def validate_pool_range(start_ip, end_ip, protocol) do
    with :ok <- validate_ip(start_ip, protocol),
         :ok <- validate_ip(end_ip, protocol),
         {:ok, start_tuple} <- :inet.parse_address(to_charlist(start_ip)),
         {:ok, end_tuple} <- :inet.parse_address(to_charlist(end_ip)),
         :ok <- compare_ip_addresses(start_tuple, end_tuple) do
      :ok
    end
  end

  defp compare_ip_addresses(start_tuple, end_tuple) do
    if ip_to_integer(start_tuple) < ip_to_integer(end_tuple) do
      :ok
    else
      {:error, "Range start must be less than range end"}
    end
  end

  defp ip_to_integer({a, b, c, d}) do
    (a <<< 24) + (b <<< 16) + (c <<< 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    (a <<< 112) + (b <<< 96) + (c <<< 80) + (d <<< 64) +
    (e <<< 48) + (f <<< 32) + (g <<< 16) + h
  end

  @spec check_overlapping_pools([AddressPool.t()], :ipv4 | :ipv6) ::
    :ok | {:error, String.t()}
  def check_overlapping_pools(pools, protocol) do
    pool_ranges =
      pools
      |> Enum.map(fn pool ->
        {:ok, start_tuple} = :inet.parse_address(to_charlist(pool.range_start))
        {:ok, end_tuple} = :inet.parse_address(to_charlist(pool.range_end))
        {pool.name, ip_to_integer(start_tuple), ip_to_integer(end_tuple)}
      end)
      |> Enum.sort_by(fn {_name, start, _end} -> start end)

    case find_overlapping_ranges(pool_ranges) do
      nil -> :ok
      {pool1, pool2} -> {:error, "Pool '#{pool1}' overlaps with pool '#{pool2}'"}
    end
  end

  defp find_overlapping_ranges([]), do: nil
  defp find_overlapping_ranges([_]), do: nil
  defp find_overlapping_ranges([{name1, _start1, end1}, {name2, start2, _end2} | rest]) do
    if end1 >= start2 do
      {name1, name2}
    else
      find_overlapping_ranges([{name2, start2, _end2} | rest])
    end
  end
end
```

---

## Summary

The data model provides:
- **Type Safety**: Ecto embedded schemas with comprehensive validation
- **No Database**: Uses TOML file storage with in-memory state
- **Optimistic Locking**: Version counter + file timestamp prevents conflicts
- **Staged Changes**: PendingChange tracking enables save/apply workflow
- **Per-Service Apply**: Independent pending state per service
- **Validation**: Reusable validators for IP addresses, ports, ranges
- **Pool Management**: Full CRUD with overlap detection

All entities follow Phoenix LiveView patterns with changesets for real-time validation and error display.
