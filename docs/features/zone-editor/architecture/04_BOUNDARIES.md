# Boundaries Layer: DNS Zone Editor

## Overview

The boundaries layer orchestrates operations across the functional core and data layer. It ensures atomicity, handles side effects, and provides a clean API for the LiveView layer.

## Module: `YellowDog.Dns.Boundaries.ZoneService`

```elixir
defmodule YellowDog.Dns.Boundaries.ZoneService do
  @moduledoc """
  Service layer for zone operations.

  Coordinates:
  - Validation (functional core)
  - Data persistence (Auth zone)
  - Change logging (History)
  - Event publishing (PubSub)

  All public functions return {:ok, result} or {:error, reason}.
  """

  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.Zone.History
  alias DNS.Zone.Validator.{Record, Zone, Result}
  alias Phoenix.PubSub

  @pubsub YellowDog.Console.PubSub

  # ============================================
  # Add Record
  # ============================================

  @doc """
  Add a record to a zone with full validation.

  ## Steps:
  1. Validate record syntax
  2. Check zone-wide rules (CNAME conflicts, etc.)
  3. Insert into zone
  4. Log change
  5. Publish event

  ## Returns
  - `{:ok, record}` on success
  - `{:error, errors}` on validation failure
  - `{:error, :conflict, details}` on zone rule violation
  """
  @spec add_record(pid(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_record(zone_pid, params, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)
    record_type = normalize_type(params[:type])

    # Step 1: Validate record syntax
    with {:ok, validated} <- Record.validate(record_type, params),
         # Step 2: Check zone rules
         existing <- Auth.get_all_records(zone_pid),
         {:ok, :no_conflict} <- Zone.check_would_conflict(validated, existing, zone_name),
         # Step 3: Build and insert record
         record <- build_record(validated, zone_name),
         :ok <- Auth.add_record(zone_pid, record) do

      # Step 4: Log change
      log_change(zone_name, :create, nil, record, opts)

      # Step 5: Publish event
      broadcast(zone_name, {:record_added, record})

      {:ok, record}
    else
      {:error, errors} when is_list(errors) ->
        {:error, {:validation, errors}}

      {:error, %{code: code} = details} ->
        {:error, {:conflict, code, details}}

      error ->
        {:error, error}
    end
  end

  # ============================================
  # Update Record
  # ============================================

  @doc """
  Update an existing record with optimistic locking.

  ## Parameters
  - `zone_pid` - Zone process
  - `name` - Record name
  - `type` - Record type
  - `params` - New record data
  - `expected_version` - Version for optimistic locking

  ## Returns
  - `{:ok, record}` on success
  - `{:error, :not_found}` if record doesn't exist
  - `{:error, :version_conflict}` if version mismatch
  - `{:error, errors}` on validation failure
  """
  @spec update_record(pid(), String.t(), atom(), map(), integer(), keyword()) ::
    {:ok, map()} | {:error, term()}
  def update_record(zone_pid, name, type, params, expected_version, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)

    # Get current record
    with {:ok, current} <- get_record(zone_pid, name, type),
         # Check version
         :ok <- check_version(current, expected_version),
         # Validate new data
         {:ok, validated} <- Record.validate(type, params),
         # Check zone rules (if name changed)
         :ok <- check_update_rules(zone_pid, current, validated, zone_name),
         # Update in zone
         record <- build_record(validated, zone_name),
         :ok <- Auth.remove_record(zone_pid, name, type),
         :ok <- Auth.add_record(zone_pid, record) do

      # Log change
      log_change(zone_name, :update, current, record, opts)

      # Publish event
      broadcast(zone_name, {:record_updated, current, record})

      {:ok, record}
    else
      {:error, :not_found} = error -> error
      {:error, :version_conflict} = error -> error
      {:error, errors} when is_list(errors) -> {:error, {:validation, errors}}
      error -> {:error, error}
    end
  end

  # ============================================
  # Delete Record
  # ============================================

  @doc """
  Delete a record from a zone.

  ## Parameters
  - `zone_pid` - Zone process
  - `name` - Record name
  - `type` - Record type
  - `expected_version` - Version for optimistic locking (optional)
  """
  @spec delete_record(pid(), String.t(), atom(), integer() | nil, keyword()) ::
    :ok | {:error, term()}
  def delete_record(zone_pid, name, type, expected_version \\ nil, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)

    with {:ok, current} <- get_record(zone_pid, name, type),
         :ok <- maybe_check_version(current, expected_version),
         :ok <- check_delete_rules(zone_pid, current, zone_name),
         :ok <- Auth.remove_record(zone_pid, name, type) do

      # Log change
      log_change(zone_name, :delete, current, nil, opts)

      # Publish event
      broadcast(zone_name, {:record_deleted, current})

      :ok
    end
  end

  # ============================================
  # Bulk Import
  # ============================================

  @doc """
  Import records from zone file content.

  ## Options
  - `:origin` - Zone origin
  - `:preview` - If true, only validate without importing

  ## Returns
  - `{:ok, %{imported: count, warnings: [...]}}` on success
  - `{:error, errors}` on parse/validation failure
  """
  @spec import_zone_file(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_zone_file(zone_pid, content, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)
    origin = Keyword.get(opts, :origin, zone_name)
    preview = Keyword.get(opts, :preview, false)

    with {:ok, records} <- DNS.Zone.Parser.Bind.parse(content, origin: origin),
         validation_result <- Zone.validate(records, zone_name),
         :ok <- check_validation_result(validation_result) do

      if preview do
        {:ok, %{
          records: records,
          count: length(records),
          validation: validation_result
        }}
      else
        # Bulk insert
        Enum.each(records, fn record ->
          Auth.add_record(zone_pid, build_record(record, zone_name))
        end)

        # Log import
        log_change(zone_name, :import, nil, %{count: length(records)}, opts)

        # Publish event
        broadcast(zone_name, {:zone_imported, length(records)})

        {:ok, %{
          imported: length(records),
          warnings: validation_result.warnings
        }}
      end
    end
  end

  # ============================================
  # Export Zone
  # ============================================

  @doc """
  Export zone to BIND format.

  ## Options
  - `:format` - :bind (default), :json

  ## Returns
  - `{:ok, content}` with formatted zone file
  """
  @spec export_zone(pid(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_zone(zone_pid, opts \\ []) do
    format = Keyword.get(opts, :format, :bind)
    zone_name = Auth.get_name(zone_pid)
    records = Auth.get_all_records(zone_pid)

    case format do
      :bind ->
        content = DNS.Zone.Formatter.to_bind(records, zone_name)
        {:ok, content}

      :json ->
        content = DNS.Zone.Formatter.to_json(records, zone_name)
        {:ok, content}

      _ ->
        {:error, :unsupported_format}
    end
  end

  # ============================================
  # Validate Zone
  # ============================================

  @doc """
  Validate entire zone and return report.

  ## Returns
  - `%DNS.Zone.Validator.Result{}` with errors, warnings, info
  """
  @spec validate_zone(pid()) :: Result.t()
  def validate_zone(zone_pid) do
    zone_name = Auth.get_name(zone_pid)
    records = Auth.get_all_records(zone_pid)
    Zone.validate(records, zone_name)
  end

  # ============================================
  # Batch Operations
  # ============================================

  @doc """
  Update TTL for multiple records.

  ## Parameters
  - `zone_pid` - Zone process
  - `filter` - `%{name: "pattern", type: :a}` or `:all`
  - `new_ttl` - New TTL value
  """
  @spec batch_update_ttl(pid(), map() | :all, integer(), keyword()) :: {:ok, integer()} | {:error, term()}
  def batch_update_ttl(zone_pid, filter, new_ttl, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)
    records = Auth.get_all_records(zone_pid)

    matching = filter_records(records, filter)

    updated_count = Enum.reduce(matching, 0, fn record, count ->
      # Remove old
      Auth.remove_record(zone_pid, record.name, record.type)

      # Add with new TTL
      new_record = %{record | ttl: new_ttl}
      Auth.add_record(zone_pid, new_record)

      # Log each change
      log_change(zone_name, :update, record, new_record, opts)

      count + 1
    end)

    broadcast(zone_name, {:batch_ttl_updated, updated_count, new_ttl})

    {:ok, updated_count}
  end

  @doc """
  Delete multiple records matching filter.
  """
  @spec batch_delete(pid(), map(), keyword()) :: {:ok, integer()} | {:error, term()}
  def batch_delete(zone_pid, filter, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)
    records = Auth.get_all_records(zone_pid)

    matching = filter_records(records, filter)

    # Check if deleting required records
    with :ok <- check_batch_delete_rules(matching, zone_name) do
      deleted_count = Enum.reduce(matching, 0, fn record, count ->
        Auth.remove_record(zone_pid, record.name, record.type)
        log_change(zone_name, :delete, record, nil, opts)
        count + 1
      end)

      broadcast(zone_name, {:batch_deleted, deleted_count})

      {:ok, deleted_count}
    end
  end

  # ============================================
  # History Operations
  # ============================================

  @doc """
  Get recent changes for a zone.
  """
  @spec get_history(pid(), integer()) :: [History.Entry.t()]
  def get_history(zone_pid, limit \\ 50) do
    # Note: History tracking needs to be implemented in Auth zone
    # This is a placeholder for the intended API
    zone_name = Auth.get_name(zone_pid)
    History.get_recent(zone_name, limit)
  end

  @doc """
  Rollback a change by ID.
  """
  @spec rollback_change(pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def rollback_change(zone_pid, change_id, opts \\ []) do
    zone_name = Auth.get_name(zone_pid)

    with {:ok, entry} <- History.find_entry(zone_name, change_id),
         :ok <- validate_rollback(entry),
         :ok <- apply_rollback(zone_pid, entry, opts) do

      History.mark_reverted(zone_name, change_id)
      broadcast(zone_name, {:change_rolled_back, change_id})

      :ok
    end
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: String.downcase(type) |> String.to_atom()

  defp build_record(params, zone_name) do
    name = expand_name(params.name, zone_name)

    %DNS.Message.Record{
      name: name,
      type: params.type,
      class: params[:class] || :in,
      ttl: params.ttl,
      rdata: params.rdata
    }
  end

  defp expand_name("", zone_name), do: zone_name
  defp expand_name("@", zone_name), do: zone_name
  defp expand_name(name, zone_name) do
    if String.ends_with?(name, ".") do
      String.trim_trailing(name, ".")
    else
      if String.ends_with?(name, zone_name) do
        name
      else
        "#{name}.#{zone_name}"
      end
    end
  end

  defp get_record(zone_pid, name, type) do
    case Auth.get_records(zone_pid, name, type) do
      [record | _] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  defp check_version(%{metadata: %{version: current}}, expected) when current != expected do
    {:error, :version_conflict}
  end
  defp check_version(_, _), do: :ok

  defp maybe_check_version(_, nil), do: :ok
  defp maybe_check_version(record, expected), do: check_version(record, expected)

  defp check_update_rules(zone_pid, current, new_params, zone_name) do
    if normalize_name(current.name) != normalize_name(new_params.name) do
      # Name changed, check for conflicts at new name
      existing = Auth.get_all_records(zone_pid)
      case Zone.check_would_conflict(new_params, existing, zone_name) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp check_delete_rules(zone_pid, record, zone_name) do
    # Don't allow deleting the last SOA or NS at apex
    cond do
      record.type == :soa ->
        {:error, {:cannot_delete, "Cannot delete SOA record"}}

      record.type == :ns and is_apex?(record.name, zone_name) ->
        ns_records = Auth.get_records(zone_pid, zone_name, :ns)
        if length(ns_records) <= 1 do
          {:error, {:cannot_delete, "Cannot delete last NS record at apex"}}
        else
          :ok
        end

      true ->
        :ok
    end
  end

  defp check_batch_delete_rules(records, zone_name) do
    has_all_apex_ns = Enum.all?(
      Enum.filter(records, &(&1.type == :ns and is_apex?(&1.name, zone_name))),
      fn _ -> true end
    )

    has_soa = Enum.any?(records, &(&1.type == :soa))

    cond do
      has_soa ->
        {:error, {:cannot_delete, "Cannot delete SOA record in batch operation"}}
      has_all_apex_ns ->
        {:error, {:cannot_delete, "Cannot delete all NS records at apex"}}
      true ->
        :ok
    end
  end

  defp check_validation_result(%Result{valid: false, errors: errors}) do
    {:error, {:validation, errors}}
  end
  defp check_validation_result(_), do: :ok

  defp filter_records(records, :all), do: records
  defp filter_records(records, %{} = filter) do
    Enum.filter(records, fn record ->
      name_match = case filter[:name] do
        nil -> true
        pattern -> String.contains?(record.name, pattern)
      end

      type_match = case filter[:type] do
        nil -> true
        type -> record.type == type
      end

      name_match and type_match
    end)
  end

  defp normalize_name(name) when is_binary(name) do
    name |> String.downcase() |> String.trim_trailing(".")
  end
  defp normalize_name(_), do: ""

  defp is_apex?(name, zone_name) do
    normalize_name(name) == normalize_name(zone_name)
  end

  defp log_change(zone_name, action, before, after_record, opts) do
    entry = History.Entry.new(action, zone_name,
      before: before,
      after: after_record,
      metadata: Keyword.get(opts, :metadata, %{})
    )

    History.add_entry(zone_name, entry)
  end

  defp broadcast(zone_name, event) do
    PubSub.broadcast(@pubsub, "zone:#{zone_name}", event)
  end

  defp validate_rollback(%{reverted: true}), do: {:error, :already_reverted}
  defp validate_rollback(%{action: :import}), do: {:error, :cannot_rollback_import}
  defp validate_rollback(_), do: :ok

  defp apply_rollback(zone_pid, %{action: :create, after: record}, opts) do
    # Rollback create = delete
    delete_record(zone_pid, record.name, record.type, nil, opts)
  end

  defp apply_rollback(zone_pid, %{action: :delete, before: record}, opts) do
    # Rollback delete = create
    zone_name = Auth.get_name(zone_pid)
    Auth.add_record(zone_pid, record)
    log_change(zone_name, :create, nil, record, Keyword.put(opts, :rollback, true))
    :ok
  end

  defp apply_rollback(zone_pid, %{action: :update, before: old_record, after: _}, opts) do
    # Rollback update = restore old
    zone_name = Auth.get_name(zone_pid)
    Auth.remove_record(zone_pid, old_record.name, old_record.type)
    Auth.add_record(zone_pid, old_record)
    log_change(zone_name, :update, nil, old_record, Keyword.put(opts, :rollback, true))
    :ok
  end
end
```

## Error Handling

### Error Types

```elixir
# Validation errors (user input issues)
{:error, {:validation, [%{field: :rdata, code: :invalid_ipv4, message: "..."}]}}

# Conflict errors (zone rule violations)
{:error, {:conflict, :cname_conflict, %{message: "CNAME conflicts with A record"}}}

# Not found
{:error, :not_found}

# Version conflict (optimistic locking)
{:error, :version_conflict}

# Operation not allowed
{:error, {:cannot_delete, "Cannot delete SOA record"}}
```

### Error Display in LiveView

```elixir
defmodule YellowDogWeb.DnsLive.RrLive.Helpers do
  def format_service_error({:validation, errors}) do
    Enum.map(errors, fn error ->
      {error.field, error.message}
    end)
    |> Enum.into(%{})
  end

  def format_service_error({:conflict, _code, %{message: msg}}) do
    %{base: msg}
  end

  def format_service_error(:version_conflict) do
    %{base: "Record was modified by another user. Please refresh and try again."}
  end

  def format_service_error({:cannot_delete, msg}) do
    %{base: msg}
  end

  def format_service_error(error) do
    %{base: "An unexpected error occurred: #{inspect(error)}"}
  end
end
```

## Transaction Boundaries

Since we're using ETS (not a traditional database), we don't have ACID transactions. However, we maintain consistency through:

### 1. Serialized Writes

All writes go through the GenServer (Auth zone), which serializes them:

```elixir
# All these operations are serialized by GenServer
Auth.add_record(pid, record)
Auth.remove_record(pid, name, type)
```

### 2. Optimistic Locking

Version checks prevent lost updates:

```elixir
# In ZoneService.update_record
with {:ok, current} <- get_record(zone_pid, name, type),
     :ok <- check_version(current, expected_version),
     # ... rest of update
```

### 3. Event-Driven Consistency

PubSub events keep LiveView UIs synchronized:

```elixir
# LiveView subscribes
def mount(_, _, socket) do
  Phoenix.PubSub.subscribe(@pubsub, "zone:#{zone_name}")
  {:ok, socket}
end

# LiveView handles events
def handle_info({:record_added, record}, socket) do
  {:noreply, stream_insert(socket, :records, record)}
end
```

### 4. Bulk Operation Patterns

For bulk operations, we iterate and accumulate errors:

```elixir
def bulk_import(zone_pid, records) do
  results = Enum.map(records, fn record ->
    case ZoneService.add_record(zone_pid, record) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end)

  errors = Enum.filter(results, &match?({:error, _}, &1))

  if Enum.empty?(errors) do
    {:ok, length(records)}
  else
    # Partial success - return what succeeded and what failed
    {:partial, %{
      succeeded: length(results) - length(errors),
      failed: errors
    }}
  end
end
```

## Testing the Service Layer

```elixir
defmodule YellowDog.Dns.Boundaries.ZoneServiceTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Boundaries.ZoneService
  alias YellowDog.Dns.Zone.Auth

  setup do
    # Start registry
    {:ok, _} = Registry.start_link(keys: :unique, name: YellowDog.Dns.ZoneRegistry)

    # Start zone
    {:ok, pid} = Auth.start_link(name: "test.example.com", records: [])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, zone: pid}
  end

  describe "add_record/3" do
    test "adds valid A record", %{zone: pid} do
      assert {:ok, record} = ZoneService.add_record(pid, %{
        name: "www",
        type: :a,
        ttl: 3600,
        rdata: "192.0.2.1"
      })

      assert record.name == "www.test.example.com"
      assert record.rdata == {192, 0, 2, 1}
    end

    test "rejects CNAME at apex", %{zone: pid} do
      assert {:error, {:conflict, :cname_at_apex, _}} =
        ZoneService.add_record(pid, %{
          name: "@",
          type: :cname,
          ttl: 3600,
          rdata: "other.com"
        })
    end

    test "rejects CNAME with existing A record", %{zone: pid} do
      {:ok, _} = ZoneService.add_record(pid, %{name: "www", type: :a, ttl: 3600, rdata: "1.2.3.4"})

      assert {:error, {:conflict, :cname_conflict, _}} =
        ZoneService.add_record(pid, %{name: "www", type: :cname, ttl: 3600, rdata: "other.com"})
    end
  end

  describe "validate_zone/1" do
    test "reports missing SOA", %{zone: pid} do
      result = ZoneService.validate_zone(pid)
      assert Enum.any?(result.errors, &(&1.code == :missing_soa))
    end
  end
end
```
