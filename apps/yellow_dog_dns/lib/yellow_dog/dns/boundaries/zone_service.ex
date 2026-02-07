defmodule YellowDog.Dns.Boundaries.ZoneService do
  @moduledoc """
  Service layer for DNS zone operations.

  Orchestrates validation, storage, and event publishing for zone record
  management. This module implements the "boundary" layer pattern - coordinating
  between pure validation functions and stateful zone storage.

  ## Features

  - Record CRUD with validation
  - CNAME conflict detection
  - PubSub event publishing for real-time UI updates
  - Full zone validation reports

  ## Examples

      # Add a record
      {:ok, record} = ZoneService.add_record(zone_pid, :a, %{
        name: "www",
        rdata: "192.0.2.1",
        ttl: 3600
      })

      # Delete a record
      :ok = ZoneService.delete_record(zone_pid, "www", :a)

      # Validate entire zone
      {:ok, result} = ZoneService.validate_zone(zone_pid)
  """

  require Logger

  alias DNS.Zone.Validator.Record, as: RecordValidator
  alias DNS.Zone.Validator.Zone, as: ZoneValidator
  alias DNS.Zone.Validator.Result
  alias YellowDog.Dns.Zone.Auth

  @pubsub YellowDog.Console.PubSub

  # ============================================
  # Record Operations
  # ============================================

  @doc """
  Add a new record to the zone.

  Validates the record, checks for conflicts, then inserts into the zone.
  Publishes a `:record_added` event on success.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process
  - `type` - Record type atom (:a, :aaaa, :cname, :mx, etc.)
  - `params` - Map with record parameters (name, rdata, ttl, etc.)

  ## Returns
  - `{:ok, record}` on success
  - `{:error, errors}` on validation failure
  - `{:error, conflict}` if record would cause a conflict

  ## Examples

      iex> add_record(zone_pid, :a, %{name: "www", rdata: "192.0.2.1", ttl: 3600})
      {:ok, %{name: "www", type: :a, class: :in, rdata: {192, 0, 2, 1}, ttl: 3600}}

      iex> add_record(zone_pid, :cname, %{name: "", rdata: "other.com."})
      {:error, %{code: :cname_at_apex, message: "Cannot create CNAME at zone apex"}}
  """
  @spec add_record(pid() | atom(), atom(), map()) ::
          {:ok, map()} | {:error, list() | map()}
  def add_record(zone_pid, type, params) do
    zone_name = Auth.get_name(zone_pid)
    existing_records = Auth.get_all_records(zone_pid)

    with {:ok, validated} <- RecordValidator.validate(type, params),
         {:ok, :no_conflict} <-
           ZoneValidator.check_would_conflict(validated, existing_records, zone_name) do
      # Build record struct for storage
      record = build_record(validated)

      # Insert into zone
      :ok = Auth.add_record(zone_pid, record)

      # Save zone to persist changes
      save_zone_async(zone_pid)

      # Publish event for real-time updates
      broadcast(zone_name, {:record_added, validated})

      {:ok, validated}
    end
  end

  @doc """
  Update an existing record in the zone.

  Removes the old record and adds the new one. Validates the new record
  and checks for conflicts before making changes.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process
  - `name` - Current record name
  - `type` - Current record type
  - `new_params` - Map with new record parameters

  ## Returns
  - `{:ok, new_record}` on success
  - `{:error, errors}` on validation failure
  - `{:error, :not_found}` if original record doesn't exist

  ## Examples

      iex> update_record(zone_pid, "www", :a, %{rdata: "192.0.2.2", ttl: 600})
      {:ok, %{name: "www", type: :a, class: :in, rdata: {192, 0, 2, 2}, ttl: 600}}
  """
  @spec update_record(pid() | atom(), String.t(), atom(), map()) ::
          {:ok, map()} | {:error, list() | map() | atom()}
  def update_record(zone_pid, name, type, new_params) do
    zone_name = Auth.get_name(zone_pid)

    # Get current records at this name/type
    current_records = Auth.get_records(zone_pid, name, type)

    if Enum.empty?(current_records) do
      {:error, :not_found}
    else
      # Keep name and type from original, update other fields
      params = Map.merge(new_params, %{name: name})

      # For updates, we need to check conflicts excluding the current record
      existing_records =
        Auth.get_all_records(zone_pid)
        |> Enum.reject(&(normalize_name(&1.name) == normalize_name(name) and &1.type == type))

      with {:ok, validated} <- RecordValidator.validate(type, params),
           {:ok, :no_conflict} <-
             ZoneValidator.check_would_conflict(validated, existing_records, zone_name) do
        # Get the old record for the event
        old_record = List.first(current_records)

        # Remove old and add new
        :ok = Auth.remove_record(zone_pid, name, type)
        record = build_record(validated)
        :ok = Auth.add_record(zone_pid, record)

        # Save zone to persist changes
        save_zone_async(zone_pid)

        # Publish update event
        broadcast(zone_name, {:record_updated, old_record, validated})

        {:ok, validated}
      end
    end
  end

  @doc """
  Delete a record from the zone.

  Checks if deletion is allowed (can't delete required SOA/NS records),
  then removes the record.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process
  - `name` - Record name to delete
  - `type` - Record type to delete

  ## Returns
  - `:ok` on success
  - `{:error, error}` if deletion is blocked or record not found

  ## Examples

      iex> delete_record(zone_pid, "www", :a)
      :ok

      iex> delete_record(zone_pid, "", :soa)
      {:error, %{code: :cannot_delete_soa, message: "Cannot delete SOA record"}}
  """
  @spec delete_record(pid() | atom(), String.t(), atom()) ::
          :ok | {:error, map() | atom()}
  def delete_record(zone_pid, name, type) do
    zone_name = Auth.get_name(zone_pid)
    existing_records = Auth.get_all_records(zone_pid)

    # Find the record to delete
    records_to_delete = Auth.get_records(zone_pid, name, type)

    if Enum.empty?(records_to_delete) do
      {:error, :not_found}
    else
      record = %{name: name, type: type}

      case ZoneValidator.check_can_delete(record, existing_records, zone_name) do
        {:ok, :can_delete} ->
          # Get record for event before deleting
          deleted_record = List.first(records_to_delete)

          :ok = Auth.remove_record(zone_pid, name, type)

          # Save zone to persist changes
          save_zone_async(zone_pid)

          # Publish delete event
          broadcast(zone_name, {:record_deleted, deleted_record})

          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Get all records in a zone.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process

  ## Returns
  - List of all records in the zone with normalized rdata values
  """
  @spec list_records(pid() | atom()) :: [map()]
  def list_records(zone_pid) do
    zone_pid
    |> Auth.get_all_records()
    |> Enum.map(&normalize_record/1)
  end

  @doc """
  Get records by name and type.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process
  - `name` - Record name
  - `type` - Record type (or `:any` for all types at this name)

  ## Returns
  - List of matching records with normalized rdata values
  """
  @spec get_records(pid() | atom(), String.t(), atom()) :: [map()]
  def get_records(zone_pid, name, type) do
    zone_pid
    |> Auth.get_records(name, type)
    |> Enum.map(&normalize_record/1)
  end

  # ============================================
  # Zone Persistence
  # ============================================

  @doc """
  Saves the zone to its configured file path.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> save_zone(zone_pid)
      :ok
  """
  @spec save_zone(pid() | atom()) :: :ok | {:error, String.t()}
  def save_zone(zone_pid) do
    Auth.save(zone_pid)
  end

  # ============================================
  # Zone Validation
  # ============================================

  @doc """
  Validate the entire zone.

  Performs all zone-level validation checks and returns a detailed
  result with errors and warnings.

  ## Parameters
  - `zone_pid` - PID or registered name of the Auth zone process

  ## Returns
  - `{:ok, result}` if zone is valid (may have warnings)
  - `{:error, result}` if zone has validation errors

  ## Examples

      iex> validate_zone(zone_pid)
      {:ok, %Result{valid?: true, errors: [], warnings: [...]}}
  """
  @spec validate_zone(pid() | atom()) :: {:ok, Result.t()} | {:error, Result.t()}
  def validate_zone(zone_pid) do
    zone_name = Auth.get_name(zone_pid)
    records = Auth.get_all_records(zone_pid)

    # Convert Auth records to simple maps for validation
    record_maps =
      Enum.map(records, fn record ->
        %{
          name: normalize_name(record.name),
          type: record.type,
          ttl: record.ttl,
          rdata: record.rdata
        }
      end)

    result = ZoneValidator.validate(record_maps, zone_name)
    Result.to_tuple(result)
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp build_record(validated) do
    # Convert validated map to a struct compatible with Auth zone
    %{
      name: validated.name,
      type: validated.type,
      class: validated.class,
      ttl: validated.ttl,
      rdata: validated.rdata
    }
  end

  # Save zone asynchronously to avoid blocking the caller
  defp save_zone_async(zone_pid) do
    Task.start(fn ->
      try do
        case Auth.save(zone_pid) do
          :ok -> :ok
          {:error, reason} -> log_save_error(zone_pid, reason)
        end
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp log_save_error(_zone_pid, "No zone file path configured") do
    # Expected when no file path is configured - no log needed
    :ok
  end

  defp log_save_error(zone_pid, reason) do
    try do
      zone_name = Auth.get_name(zone_pid)
      Logger.warning("Failed to save zone", zone: zone_name, error: reason)
    rescue
      _e in [ArgumentError, RuntimeError, FunctionClauseError] -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp broadcast(zone_name, message) do
    topic = "zone:#{zone_name}"

    # Only broadcast if PubSub is available
    # Use apply/3 to avoid compile-time dependency on Phoenix.PubSub
    if pubsub_available?() do
      try do
        apply(Phoenix.PubSub, :broadcast, [@pubsub, topic, message])
      rescue
        _e in [ArgumentError, UndefinedFunctionError] -> :ok
      end
    end

    :ok
  end

  defp pubsub_available? do
    case Process.whereis(@pubsub) do
      nil -> false
      _pid -> true
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_name(%{value: value}), do: normalize_name(value)
  defp normalize_name(_), do: ""

  # Normalize a record from Auth zone, converting rdata to string via protocol
  defp normalize_record(record) do
    %{
      name: normalize_name(record.name),
      type: normalize_type(record.type),
      class: record.class,
      ttl: record.ttl,
      rdata: rdata_to_string(record.rdata)
    }
  end

  # Extract the actual type atom from RRType struct
  defp normalize_type(%{value: value}), do: value
  defp normalize_type(type) when is_atom(type), do: type

  # Convert rdata to string - use String.Chars protocol if available
  defp rdata_to_string(rdata) when is_struct(rdata) do
    to_string(rdata)
  end

  defp rdata_to_string(rdata) when is_binary(rdata), do: rdata
  defp rdata_to_string(rdata), do: inspect(rdata)
end
