defmodule DNS.Zone.Validator.Zone do
  @moduledoc """
  Zone-wide validation rules.

  Checks relationships between records and zone integrity.
  This module contains pure functions that validate zone consistency
  according to DNS RFCs.

  ## Validation Rules

  **Errors (blocking):**
  - SOA record must exist at apex
  - NS records must exist at apex
  - CNAME cannot coexist with other record types at same name
  - CNAME cannot exist at zone apex

  **Warnings (non-blocking):**
  - Only one NS record (should have at least 2 for redundancy)
  - MX/NS targets pointing to CNAMEs (RFC violation)
  - TTL inconsistency within RRSets
  - Orphaned targets (no A/AAAA record for target)

  ## Examples

      iex> records = [
      ...>   %{name: "", type: :soa, rdata: %{...}},
      ...>   %{name: "", type: :ns, rdata: "ns1.example.com."},
      ...>   %{name: "", type: :ns, rdata: "ns2.example.com."}
      ...> ]
      iex> result = DNS.Zone.Validator.Zone.validate(records, "example.com")
      iex> DNS.Zone.Validator.Result.valid?(result)
      true
  """

  alias DNS.Zone.Validator.Result

  # ============================================
  # Main Validation Entry Point
  # ============================================

  @doc """
  Validate a complete zone.

  ## Parameters
  - `records` - List of record maps with `:name`, `:type`, `:ttl`, `:rdata`
  - `zone_name` - The zone's apex name (e.g., "example.com")

  ## Returns
  - `%Result{}` with errors and warnings
  """
  @spec validate(list(map()), String.t()) :: Result.t()
  def validate(records, zone_name) do
    Result.new()
    |> check_soa(records, zone_name)
    |> check_ns_at_apex(records, zone_name)
    |> check_cname_exclusivity(records)
    |> check_no_cname_at_apex(records, zone_name)
    |> check_mx_ns_targets(records)
    |> check_ttl_consistency(records)
    |> check_orphaned_targets(records)
  end

  # ============================================
  # Conflict Detection (Pre-Insert)
  # ============================================

  @doc """
  Check if adding a record would create a conflict.

  This is used for pre-insertion validation before adding
  a record to an existing zone.

  ## Parameters
  - `new_record` - The record to be added
  - `existing_records` - Current records in the zone
  - `zone_name` - The zone's apex name

  ## Returns
  - `{:ok, :no_conflict}` if the record can be safely added
  - `{:error, error_map}` if adding would cause a conflict

  ## Examples

      iex> new_record = %{name: "www", type: :a, rdata: {192, 0, 2, 1}}
      iex> existing = []
      iex> check_would_conflict(new_record, existing, "example.com")
      {:ok, :no_conflict}

      iex> new_record = %{name: "", type: :cname, rdata: "other.com."}
      iex> check_would_conflict(new_record, [], "example.com")
      {:error, %{code: :cname_at_apex, message: "Cannot create CNAME at zone apex"}}
  """
  @spec check_would_conflict(map(), list(map()), String.t()) ::
          {:ok, :no_conflict} | {:error, map()}
  def check_would_conflict(new_record, existing_records, zone_name) do
    name = normalize_name(new_record[:name] || new_record.name)
    type = new_record[:type] || new_record.type

    cond do
      # Check CNAME at apex - never allowed
      type == :cname and is_apex?(name, zone_name) ->
        {:error,
         %{
           code: :cname_at_apex,
           message: "Cannot create CNAME at zone apex"
         }}

      # Check CNAME exclusivity - new CNAME conflicts with existing records
      type == :cname ->
        check_new_cname_conflict(name, existing_records)

      # Check existing CNAME blocks new record
      true ->
        check_blocked_by_cname(name, existing_records)
    end
  end

  @doc """
  Check if deleting a record would break zone requirements.

  ## Parameters
  - `record` - The record to be deleted
  - `existing_records` - Current records in the zone
  - `zone_name` - The zone's apex name

  ## Returns
  - `{:ok, :can_delete}` if the record can be safely deleted
  - `{:error, error_map}` if deletion would break zone requirements
  """
  @spec check_can_delete(map(), list(map()), String.t()) ::
          {:ok, :can_delete} | {:error, map()}
  def check_can_delete(record, existing_records, zone_name) do
    name = record[:name] || record.name
    type = record[:type] || record.type

    cond do
      # Cannot delete SOA at apex
      type == :soa and is_apex?(name, zone_name) ->
        {:error, %{code: :cannot_delete_soa, message: "Cannot delete SOA record"}}

      # Cannot delete last NS at apex
      type == :ns and is_apex?(name, zone_name) ->
        ns_count = count_apex_records_by_type(existing_records, zone_name, :ns)

        if ns_count <= 1 do
          {:error,
           %{code: :cannot_delete_last_ns, message: "Cannot delete last NS record at apex"}}
        else
          {:ok, :can_delete}
        end

      true ->
        {:ok, :can_delete}
    end
  end

  # ============================================
  # Individual Validation Checks
  # ============================================

  defp check_soa(result, records, zone_name) do
    soa_records = filter_apex_records_by_type(records, zone_name, :soa)

    case length(soa_records) do
      0 ->
        Result.add_error(result, :missing_soa, "Zone must have exactly one SOA record at apex")

      1 ->
        result

      n ->
        Result.add_error(
          result,
          :multiple_soa,
          "Zone has #{n} SOA records, must have exactly one"
        )
    end
  end

  defp check_ns_at_apex(result, records, zone_name) do
    ns_records = filter_apex_records_by_type(records, zone_name, :ns)

    case length(ns_records) do
      0 ->
        Result.add_error(result, :missing_ns, "Zone must have at least one NS record at apex")

      1 ->
        Result.add_warning(
          result,
          :single_ns,
          "Zone has only 1 NS record; recommend at least 2 for redundancy"
        )

      _ ->
        result
    end
  end

  defp check_cname_exclusivity(result, records) do
    # Group records by normalized name
    by_name = Enum.group_by(records, &normalize_name(get_name(&1)))

    Enum.reduce(by_name, result, fn {name, recs}, acc ->
      types = recs |> Enum.map(&get_type(&1)) |> Enum.uniq()

      if :cname in types and match?([_, _ | _], types) do
        other_types = Enum.reject(types, &(&1 == :cname))

        Result.add_error(
          acc,
          :cname_conflict,
          "CNAME at '#{display_name(name)}' conflicts with #{format_types(other_types)} records",
          name: name
        )
      else
        acc
      end
    end)
  end

  defp check_no_cname_at_apex(result, records, zone_name) do
    cname_at_apex =
      Enum.any?(records, &(is_apex?(get_name(&1), zone_name) and get_type(&1) == :cname))

    if cname_at_apex do
      Result.add_error(result, :cname_at_apex, "CNAME record cannot exist at zone apex")
    else
      result
    end
  end

  defp check_mx_ns_targets(result, records) do
    # Build a set of names that have CNAME records
    cnames =
      records
      |> Enum.filter(&(get_type(&1) == :cname))
      |> Enum.map(&normalize_name(get_name(&1)))
      |> MapSet.new()

    # Check MX and NS targets
    mx_ns_records = Enum.filter(records, &(get_type(&1) in [:mx, :ns]))

    Enum.reduce(mx_ns_records, result, fn record, acc ->
      target = get_target(record)

      if target && MapSet.member?(cnames, normalize_name(target)) do
        type_name = record |> get_type() |> to_string() |> String.upcase()

        Result.add_error(
          acc,
          :target_is_cname,
          "#{type_name} target '#{target}' is a CNAME (forbidden by RFC 1034)",
          name: get_name(record)
        )
      else
        acc
      end
    end)
  end

  defp check_ttl_consistency(result, records) do
    # Group by (name, type) = RRSet
    rrsets = Enum.group_by(records, &{normalize_name(get_name(&1)), get_type(&1)})

    Enum.reduce(rrsets, result, fn {{name, type}, recs}, acc ->
      ttls = recs |> Enum.map(&get_ttl(&1)) |> Enum.uniq()

      if match?([_, _ | _], ttls) do
        Result.add_warning(
          acc,
          :ttl_mismatch,
          "TTL mismatch in RRSet '#{display_name(name)}/#{type}': #{inspect(ttls)}",
          name: name
        )
      else
        acc
      end
    end)
  end

  defp check_orphaned_targets(result, records) do
    # Get all defined names with A/AAAA records
    names_with_address =
      records
      |> Enum.filter(&(get_type(&1) in [:a, :aaaa]))
      |> Enum.map(&normalize_name(get_name(&1)))
      |> MapSet.new()

    # Check MX, NS, SRV targets
    target_records = Enum.filter(records, &(get_type(&1) in [:mx, :ns, :srv]))

    Enum.reduce(target_records, result, fn record, acc ->
      target = get_target(record)

      if target && not target_resolvable?(target, names_with_address) do
        type_name = record |> get_type() |> to_string() |> String.upcase()

        Result.add_warning(
          acc,
          :orphaned_target,
          "#{type_name} target '#{target}' has no A/AAAA record in this zone",
          name: get_name(record)
        )
      else
        acc
      end
    end)
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp check_new_cname_conflict(name, existing_records) do
    existing_at_name =
      Enum.filter(existing_records, &(normalize_name(get_name(&1)) == name))

    if Enum.any?(existing_at_name) do
      types = existing_at_name |> Enum.map(&get_type(&1)) |> Enum.uniq()

      {:error,
       %{
         code: :cname_conflict,
         message: "CNAME would conflict with existing #{format_types(types)} records"
       }}
    else
      {:ok, :no_conflict}
    end
  end

  defp check_blocked_by_cname(name, existing_records) do
    cnames_at_name =
      Enum.filter(
        existing_records,
        &(normalize_name(get_name(&1)) == name and get_type(&1) == :cname)
      )

    if Enum.any?(cnames_at_name) do
      {:error,
       %{
         code: :blocked_by_cname,
         message: "Cannot add record: CNAME exists at this name"
       }}
    else
      {:ok, :no_conflict}
    end
  end

  defp filter_apex_records_by_type(records, zone_name, type) do
    Enum.filter(records, &(is_apex?(get_name(&1), zone_name) and get_type(&1) == type))
  end

  defp count_apex_records_by_type(records, zone_name, type) do
    records
    |> filter_apex_records_by_type(zone_name, type)
    |> length()
  end

  defp normalize_name(nil), do: ""
  defp normalize_name(""), do: ""
  defp normalize_name("@"), do: ""

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_name(%{value: value}), do: normalize_name(value)
  defp normalize_name(_), do: ""

  defp is_apex?(name, zone_name) do
    normalize_name(name) == normalize_name(zone_name) or name == "" or name == "@"
  end

  # Extract name from various record formats
  defp get_name(%{name: name}), do: name
  defp get_name(_), do: ""

  # Extract type from various record formats
  defp get_type(%{type: type}), do: type
  defp get_type(_), do: nil

  # Extract TTL from various record formats
  defp get_ttl(%{ttl: ttl}), do: ttl
  defp get_ttl(_), do: nil

  # Extract target from MX, NS, SRV records
  defp get_target(%{type: :mx, rdata: {_priority, target}}), do: target
  defp get_target(%{type: :ns, rdata: target}) when is_binary(target), do: target
  defp get_target(%{type: :srv, rdata: {_pri, _weight, _port, target}}), do: target
  defp get_target(_), do: nil

  defp target_resolvable?(target, names_with_address) do
    normalized = normalize_name(String.trim_trailing(target, "."))

    # Check if target exists in this zone's address records
    # Note: External targets (different zone) are acceptable
    # So we only warn if it looks like an internal reference
    MapSet.member?(names_with_address, normalized)
  end

  defp format_types(types) do
    types
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.join(", ")
  end

  defp display_name(""), do: "@"
  defp display_name(name), do: name
end
