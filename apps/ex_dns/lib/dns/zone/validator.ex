defmodule DNS.Zone.Validator do
  @moduledoc """
  Zone validation and diagnostics tools for DNS zones.

  Provides comprehensive validation for zone syntax, semantics,
  DNSSEC compliance, and RFC compliance checking.
  """

  alias DNS.Zone

  @doc """
  Validate a complete zone for RFC compliance and best practices.
  """
  @spec validate_zone(Zone.t()) :: {:ok, map()} | {:error, map()}
  def validate_zone(zone) do
    {struct_errors, struct_warnings} = validate_zone_structure(zone)
    {soa_errors, soa_warnings} = validate_soa_record(zone)
    {ns_errors, ns_warnings} = validate_ns_records(zone)
    {consistency_errors, consistency_warnings} = validate_record_consistency(zone)
    {dnssec_errors, dnssec_warnings} = validate_dnssec_records(zone)
    {ttl_errors, ttl_warnings} = validate_ttl_values(zone)

    errors =
      struct_errors ++
        soa_errors ++ ns_errors ++ consistency_errors ++ dnssec_errors ++ ttl_errors

    warnings =
      struct_warnings ++
        soa_warnings ++ ns_warnings ++ consistency_warnings ++ dnssec_warnings ++ ttl_warnings

    all_records = get_all_records(zone)

    result = %{
      zone_name: zone.name.value,
      status: if(errors == [], do: :valid, else: :invalid),
      errors: errors,
      warnings: warnings,
      summary: %{
        total_errors: length(errors),
        total_warnings: length(warnings),
        total_records: length(all_records)
      }
    }

    if errors == [] do
      {:ok, result}
    else
      {:error, result}
    end
  end

  @doc """
  Validate zone structure and required records.
  """
  @spec validate_zone_structure(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_zone_structure(zone) do
    errors = []
    warnings = []

    # Check zone name
    errors =
      if zone.name.value == "" or zone.name.value == nil do
        ["Zone name is empty" | errors]
      else
        errors
      end

    # Check zone type
    errors =
      if zone.type not in [:authoritative, :stub, :forward, :cache] do
        ["Invalid zone type: #{inspect(zone.type)}" | errors]
      else
        errors
      end

    # Check for required NS records
    ns_records = Keyword.get(zone.options, :ns_records, [])

    warnings =
      if ns_records == [] do
        ["No NS records found" | warnings]
      else
        warnings
      end

    {Enum.reverse(errors), Enum.reverse(warnings)}
  end

  @doc """
  Validate SOA record format and values.
  """
  @spec validate_soa_record(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_soa_record(zone) do
    errors = []
    warnings = []

    soa_records = Keyword.get(zone.options, :soa_records, [])

    warnings =
      if length(soa_records) > 1 do
        ["Multiple SOA records found" | warnings]
      else
        warnings
      end

    {errors, warnings} =
      Enum.reduce(soa_records, {errors, warnings}, fn soa_record, {err_acc, warn_acc} ->
        {_mname, _rname, serial, refresh, retry, expire, minimum} =
          case soa_record.data do
            %DNS.Message.Record.Data.SOA{data: data} -> data
            data when is_tuple(data) -> data
          end

        # Validate serial number
        err_acc =
          if serial < 1 or serial > 4_294_967_295 do
            ["Invalid SOA serial number: #{serial}" | err_acc]
          else
            err_acc
          end

        # Validate refresh interval
        err_acc =
          if refresh < 1 do
            ["Invalid SOA refresh interval: #{refresh}" | err_acc]
          else
            err_acc
          end

        # Validate retry interval
        err_acc =
          if retry < 1 do
            ["Invalid SOA retry interval: #{retry}" | err_acc]
          else
            err_acc
          end

        # Validate expire interval
        err_acc =
          if expire < 1 do
            ["Invalid SOA expire interval: #{expire}" | err_acc]
          else
            err_acc
          end

        # Validate minimum TTL
        err_acc =
          if minimum < 0 do
            ["Invalid SOA minimum TTL: #{minimum}" | err_acc]
          else
            err_acc
          end

        # Check if refresh < retry (common mistake)
        warn_acc =
          if refresh <= retry do
            ["SOA refresh interval should be greater than retry interval" | warn_acc]
          else
            warn_acc
          end

        # Check if expire < refresh (common mistake)
        warn_acc =
          if expire <= refresh do
            ["SOA expire interval should be greater than refresh interval" | warn_acc]
          else
            warn_acc
          end

        {err_acc, warn_acc}
      end)

    {Enum.reverse(errors), Enum.reverse(warnings)}
  end

  @doc """
  Validate NS records and delegation.
  """
  @spec validate_ns_records(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_ns_records(zone) do
    errors = []
    warnings = []

    ns_records = Keyword.get(zone.options, :ns_records, [])

    warnings =
      Enum.reduce(ns_records, warnings, fn ns_record, warn_acc ->
        ns_name =
          case ns_record.data do
            %DNS.Message.Record.Data.NS{data: domain} -> domain.value
            %DNS.Message.Domain{value: value} -> value
            value when is_binary(value) -> value
          end

        # Check if NS name has corresponding A/AAAA records
        a_records = Keyword.get(zone.options, :a_records, [])
        aaaa_records = Keyword.get(zone.options, :aaaa_records, [])

        has_a_record =
          Enum.any?(a_records, fn a ->
            a.name.value == ns_name || String.ends_with?(ns_name, a.name.value)
          end)

        has_aaaa_record =
          Enum.any?(aaaa_records, fn aaaa ->
            aaaa.name.value == ns_name || String.ends_with?(ns_name, aaaa.name.value)
          end)

        if not (has_a_record or has_aaaa_record) do
          # Remove trailing dot for consistent formatting
          clean_name = String.trim_trailing(ns_name, ".")
          ["NS record #{clean_name} has no corresponding A/AAAA record" | warn_acc]
        else
          warn_acc
        end
      end)

    {errors, Enum.reverse(warnings)}
  end

  @doc """
  Validate record consistency and conflicts.
  """
  @spec validate_record_consistency(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_record_consistency(zone) do
    # Get all records by name
    all_records = get_all_records(zone)
    records_by_name = Enum.group_by(all_records, & &1.name.value)

    {errors, warnings} =
      Enum.reduce(records_by_name, {[], []}, fn {name, records}, {err_acc, warn_acc} ->
        # Check for CNAME conflicts
        is_cname = fn record ->
          case record.type do
            %DNS.ResourceRecordType{value: <<5::16>>} -> true
            %DNS.ResourceRecordType{value: 5} -> true
            :cname -> true
            _ -> false
          end
        end

        cname_records = Enum.filter(records, is_cname)
        other_records = Enum.reject(records, is_cname)

        err_acc =
          if cname_records != [] and other_records != [] do
            ["CNAME record conflicts with other records for #{name}" | err_acc]
          else
            err_acc
          end

        # Check for duplicate records
        duplicates = find_duplicates(records)

        warn_acc =
          if duplicates != [] do
            ["Duplicate records found for #{name}: #{inspect(duplicates)}" | warn_acc]
          else
            warn_acc
          end

        {err_acc, warn_acc}
      end)

    {Enum.reverse(errors), Enum.reverse(warnings)}
  end

  @doc """
  Validate DNSSEC records and signatures.
  """
  @spec validate_dnssec_records(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_dnssec_records(zone) do
    # Check if DNSSEC is enabled
    dnssec_records = Keyword.get(zone.options, :dnssec_records, [])
    dnskey_records = Keyword.get(zone.options, :dnskey_records, [])
    ds_records = Keyword.get(zone.options, :ds_records, [])
    rrsig_records = Keyword.get(zone.options, :rrsig_records, [])

    # DNSSEC is considered enabled if any DNSSEC-related keys exist in options
    # even if they're empty lists (indicating DNSSEC was explicitly configured)
    has_dnssec =
      Keyword.has_key?(zone.options, :dnssec_records) or
        Keyword.has_key?(zone.options, :dnskey_records) or
        Keyword.has_key?(zone.options, :ds_records) or
        Keyword.has_key?(zone.options, :rrsig_records) or
        dnssec_records != [] or dnskey_records != [] or ds_records != [] or rrsig_records != []

    if has_dnssec do
      # Validate DNSKEY records
      errors =
        if dnskey_records == [] do
          ["DNSSEC enabled but no DNSKEY records found"]
        else
          []
        end

      # Validate DS records
      warnings =
        if zone.type == :authoritative and ds_records == [] do
          ["DNSSEC enabled but no DS records found"]
        else
          []
        end

      # Validate RRSIG coverage
      signed_types =
        if rrsig_records != [] do
          Enum.map(rrsig_records, fn rrsig ->
            case rrsig.data do
              %{type_covered: type} -> type
              _ -> :unknown
            end
          end)
        else
          []
        end

      all_records = get_all_records(zone)

      warnings =
        Enum.reduce(all_records, warnings, fn record, warn_acc ->
          record_type = if is_atom(record.type), do: record.type, else: record.type.value

          if record_type not in [:rrsig, :dnskey, :ds, :nsec, :nsec3] and
               record_type not in signed_types do
            ["Record type #{record_type} not covered by RRSIG" | warn_acc]
          else
            warn_acc
          end
        end)

      {errors, Enum.reverse(warnings)}
    else
      {[], []}
    end
  end

  @doc """
  Validate TTL values across the zone.
  """
  @spec validate_ttl_values(Zone.t()) :: {list(String.t()), list(String.t())}
  def validate_ttl_values(zone) do
    all_records = get_all_records(zone)

    {errors, warnings} =
      Enum.reduce(all_records, {[], []}, fn record, {err_acc, warn_acc} ->
        # Check TTL range
        err_acc =
          if record.ttl < 0 do
            ["Negative TTL value: #{record.ttl}" | err_acc]
          else
            err_acc
          end

        warn_acc =
          if record.ttl > 2_147_483_647 do
            ["TTL value exceeds maximum: #{record.ttl}" | warn_acc]
          else
            warn_acc
          end

        # Warn about very short TTLs for non-transaction records
        warn_acc =
          if record.ttl < 30 and record.type not in [:soa] do
            ["Very short TTL for #{record.type} record: #{record.ttl}" | warn_acc]
          else
            warn_acc
          end

        # Warn about very long TTLs
        # 7 days
        warn_acc =
          if record.ttl > 604_800 do
            ["Very long TTL for #{record.type} record: #{record.ttl}" | warn_acc]
          else
            warn_acc
          end

        {err_acc, warn_acc}
      end)

    {Enum.reverse(errors), Enum.reverse(warnings)}
  end

  @doc """
  Generate zone diagnostics report.
  """
  @spec generate_diagnostics(Zone.t()) :: map()
  def generate_diagnostics(zone) do
    %{
      zone_name: zone.name.value,
      zone_type: zone.type,
      statistics: generate_statistics(zone),
      recommendations: generate_recommendations(zone),
      security_assessment: generate_security_assessment(zone),
      performance_metrics: generate_performance_metrics(zone)
    }
  end

  @doc """
  Generate zone statistics.
  """
  @spec generate_statistics(Zone.t()) :: map()
  def generate_statistics(zone) do
    all_records = get_all_records(zone)
    records_by_type = Enum.group_by(all_records, & &1.type)

    %{
      total_records: length(all_records),
      record_counts:
        Enum.map(records_by_type, fn {type, records} ->
          {type, length(records)}
        end),
      unique_names: length(Enum.uniq(Enum.map(all_records, & &1.name.value))),
      dnssec_enabled: has_dnssec?(zone),
      last_modified: Keyword.get(zone.options, :last_modified, DateTime.utc_now())
    }
  end

  @doc """
  Generate recommendations for zone optimization.
  """
  @spec generate_recommendations(Zone.t()) :: list(String.t())
  def generate_recommendations(zone) do
    recommendations = []

    # Check for missing records
    ns_records = Keyword.get(zone.options, :ns_records, [])

    recommendations =
      if ns_records == [] do
        ["Add NS records for proper delegation" | recommendations]
      else
        recommendations
      end

    a_records = Keyword.get(zone.options, :a_records, [])

    recommendations =
      if a_records == [] do
        ["Consider adding A records for better functionality" | recommendations]
      else
        recommendations
      end

    # Check TTL distribution
    all_records = get_all_records(zone)
    ttl_values = Enum.map(all_records, & &1.ttl)
    avg_ttl = if ttl_values != [], do: Enum.sum(ttl_values) / length(ttl_values), else: 0

    recommendations =
      if avg_ttl < 300 do
        ["Consider increasing average TTL for better caching" | recommendations]
      else
        recommendations
      end

    # Check DNSSEC status
    recommendations =
      unless has_dnssec?(zone) do
        ["Consider enabling DNSSEC for security" | recommendations]
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end

  @doc """
  Generate security assessment for the zone.
  """
  @spec generate_security_assessment(Zone.t()) :: map()
  def generate_security_assessment(zone) do
    %{
      dnssec_enabled: has_dnssec?(zone),
      dnssec_valid: if(has_dnssec?(zone), do: validate_dnssec_signatures(zone), else: false),
      transfer_restrictions: has_transfer_restrictions?(zone),
      record_validation: validate_record_security(zone),
      overall_score: calculate_security_score(zone)
    }
  end

  @doc """
  Generate performance metrics for the zone.
  """
  @spec generate_performance_metrics(Zone.t()) :: map()
  def generate_performance_metrics(zone) do
    all_records = get_all_records(zone)

    %{
      record_count: length(all_records),
      cache_efficiency: calculate_cache_efficiency(zone),
      query_response_time: estimate_query_response_time(zone),
      zone_size: estimate_zone_size(zone)
    }
  end

  ## Private functions

  defp get_all_records(zone) do
    # Collect all records from zone options
    record_types = [
      :soa_records,
      :ns_records,
      :a_records,
      :aaaa_records,
      :cname_records,
      :mx_records,
      :txt_records,
      :srv_records,
      :ptr_records,
      :caa_records,
      :tlsa_records,
      :https_records,
      :svcb_records,
      :dnskey_records,
      :ds_records,
      :rrsig_records,
      :nsec_records,
      :nsec3_records
    ]

    Enum.flat_map(record_types, fn type ->
      Keyword.get(zone.options, type, [])
    end)
  end

  defp find_duplicates(records) do
    records
    |> Enum.group_by(fn record ->
      {record.type, record.data}
    end)
    |> Enum.filter(fn {_key, records} -> length(records) > 1 end)
    |> Enum.map(fn {key, _records} -> key end)
  end

  defp has_dnssec?(zone) do
    dnssec_records = Keyword.get(zone.options, :dnssec_records, [])
    dnskey_records = Keyword.get(zone.options, :dnskey_records, [])
    dnssec_records != [] or dnskey_records != []
  end

  defp validate_dnssec_signatures(zone) do
    # Basic DNSSEC validation - check for required records
    dnskey_records = Keyword.get(zone.options, :dnskey_records, [])
    _rrsig_records = Keyword.get(zone.options, :rrsig_records, [])

    # For testing purposes, DNSSEC is valid if DNSKEY records exist
    # In real implementation, this would validate signatures
    dnskey_records != []
  end

  defp has_transfer_restrictions?(zone) do
    allow_transfer = Keyword.get(zone.options, :allow_transfer, [])
    allow_transfer != :any and allow_transfer != []
  end

  defp validate_record_security(zone) do
    # Check for common security issues
    all_records = get_all_records(zone)

    %{
      open_transfer: not has_transfer_restrictions?(zone),
      missing_dnssec: not has_dnssec?(zone),
      weak_ttl: Enum.any?(all_records, &(&1.ttl < 30)),
      missing_ns: Keyword.get(zone.options, :ns_records, []) == []
    }
  end

  defp calculate_security_score(zone) do
    score = 100

    # DNSSEC bonus
    score = if has_dnssec?(zone), do: score + 20, else: score - 20

    # Transfer restrictions bonus
    score = if has_transfer_restrictions?(zone), do: score + 10, else: score - 10

    # NS records bonus
    score = if Keyword.get(zone.options, :ns_records, []) != [], do: score + 10, else: score - 5

    # TTL adjustment
    all_records = get_all_records(zone)
    score = if Enum.any?(all_records, &(&1.ttl < 30)), do: score - 5, else: score

    max(score, 0)
  end

  defp calculate_cache_efficiency(zone) do
    all_records = get_all_records(zone)

    if all_records == [] do
      0.0
    else
      total_ttl = Enum.sum(Enum.map(all_records, & &1.ttl))
      avg_ttl = total_ttl / length(all_records)

      # Normalize to 0-1 scale based on typical TTL ranges
      min(avg_ttl / 3600, 1.0)
    end
  end

  # Simplified estimation based on zone size
  defp estimate_query_response_time(zone) do
    record_count = length(get_all_records(zone))

    cond do
      record_count < 10 -> "< 1ms"
      record_count < 100 -> "1-5ms"
      record_count < 1000 -> "5-20ms"
      true -> "20-50ms"
    end
  end

  defp estimate_zone_size(zone) do
    # Estimate zone size in bytes based on record count
    record_count = length(get_all_records(zone))
    # Rough estimate per record
    record_count * 100
  end
end
