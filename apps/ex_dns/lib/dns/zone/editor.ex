defmodule DNS.Zone.Editor do
  @moduledoc """
  Zone editor interface for interactive zone management.

  Provides a high-level interface for zone creation, modification, and management
  with built-in validation and error handling.
  """

  alias DNS.Zone
  alias DNS.Zone.Name
  alias DNS.Zone.Manager
  alias DNS.Zone.Validator
  alias DNS.Zone.DNSSEC
  alias DNS.Message.Record

  @doc """
  Create a new zone with interactive prompts.
  """
  @spec create_zone_interactive(String.t(), keyword()) :: {:ok, Zone.t()} | {:error, String.t()}
  def create_zone_interactive(zone_name, options \\ []) do
    zone_name = normalize_zone_name(zone_name)

    # Validate zone name
    unless valid_zone_name?(zone_name) do
      {:error, "Invalid zone name format: #{zone_name}"}
    else
      # Check if zone already exists
      case Manager.get_zone(zone_name) do
        {:ok, _existing} ->
          {:error, "Zone already exists: #{zone_name}"}

        {:error, :not_found} ->
          # Create new zone
          zone_type = Keyword.get(options, :type, :authoritative)
          zone = Zone.new(zone_name, zone_type)

          # Add initial records if provided
          zone = add_initial_records(zone, options)

          # Validate zone before saving
          case Validator.validate_zone(zone) do
            {:ok, _} ->
              Manager.create_zone(zone_name, zone_type, zone.options)

            {:error, validation_result} ->
              {:error, "Zone validation failed: #{inspect(validation_result.errors)}"}
          end
      end
    end
  end

  @doc """
  Add a record to a zone.
  """
  @spec add_record(String.t() | Name.t(), atom(), keyword()) ::
          {:ok, Zone.t()} | {:error, String.t()}
  def add_record(zone_name, record_type, options) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        record = create_record(zone_name, record_type, options)

        # Add record to appropriate category
        record_key = String.to_atom("#{record_type}_records")
        existing_records = Keyword.get(zone.options, record_key, [])
        updated_records = [record | existing_records]

        # Update zone options
        updated_options = Keyword.put(zone.options, record_key, updated_records)
        updated_zone = %{zone | options: updated_options}

        # Validate zone after modification
        case Validator.validate_zone(updated_zone) do
          {:ok, _} ->
            Manager.update_zone(zone_name, updated_zone.options)
            {:ok, updated_zone}

          {:error, validation_result} ->
            {:error, "Record validation failed: #{inspect(validation_result.errors)}"}
        end

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Remove a record from a zone.
  """
  @spec remove_record(String.t() | Name.t(), atom(), keyword()) ::
          {:ok, Zone.t()} | {:error, String.t()}
  def remove_record(zone_name, record_type, options) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        record_key = String.to_atom("#{record_type}_records")
        existing_records = Keyword.get(zone.options, record_key, [])

        # Find matching records
        {removed, remaining} = find_and_remove_records(existing_records, options)

        if removed == [] do
          {:error, "No matching records found"}
        else
          # Update zone options
          updated_options = Keyword.put(zone.options, record_key, remaining)
          updated_zone = %{zone | options: updated_options}

          Manager.update_zone(zone_name, updated_zone.options)
          {:ok, updated_zone}
        end

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Update an existing record in a zone.
  """
  @spec update_record(String.t() | Name.t(), atom(), keyword(), keyword()) ::
          {:ok, Zone.t()} | {:error, String.t()}
  def update_record(zone_name, record_type, match_options, update_options) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        record_key = String.to_atom("#{record_type}_records")
        existing_records = Keyword.get(zone.options, record_key, [])

        # Find and update matching records
        {updated, count} =
          update_matching_records(existing_records, match_options, update_options)

        if count == 0 do
          {:error, "No matching records found"}
        else
          # Update zone options
          updated_options = Keyword.put(zone.options, record_key, updated)
          updated_zone = %{zone | options: updated_options}

          # Validate zone after modification
          case Validator.validate_zone(updated_zone) do
            {:ok, _} ->
              Manager.update_zone(zone_name, updated_zone.options)
              {:ok, updated_zone}

            {:error, validation_result} ->
              {:error, "Record validation failed: #{inspect(validation_result.errors)}"}
          end
        end

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  List all records in a zone.
  """
  @spec list_records(String.t() | Name.t()) :: {:ok, list(map())} | {:error, String.t()}
  def list_records(zone_name) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        records = get_all_records(zone)

        formatted_records =
          Enum.map(records, fn record ->
            %{
              name: record.name.value,
              type: record.type,
              class: record.class,
              ttl: record.ttl,
              data: format_record_data(record)
            }
          end)

        {:ok, formatted_records}

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Search for records by name, type, or value.
  """
  @spec search_records(String.t() | Name.t(), keyword()) ::
          {:ok, list(map())} | {:error, String.t()}
  def search_records(zone_name, search_options) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        all_records = get_all_records(zone)

        matching_records =
          Enum.filter(all_records, fn record ->
            match_record?(record, search_options)
          end)

        formatted_records =
          Enum.map(matching_records, fn record ->
            %{
              name: record.name.value,
              type: record.type,
              class: record.class,
              ttl: record.ttl,
              data: format_record_data(record)
            }
          end)

        {:ok, formatted_records}

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Enable DNSSEC for a zone.
  """
  @spec enable_dnssec(String.t() | Name.t(), keyword()) :: {:ok, Zone.t()} | {:error, String.t()}
  def enable_dnssec(zone_name, options \\ []) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        case DNSSEC.sign_zone(zone, options) do
          {:ok, signed_zone} ->
            Manager.update_zone(zone_name, signed_zone)
            {:ok, signed_zone}

          {:error, _reason} ->
            {:error, "DNSSEC signing failed: #{zone_name}"}
        end

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Validate a zone and provide feedback.
  """
  @spec validate_zone(String.t() | Name.t()) :: {:ok, map()} | {:error, String.t()}
  def validate_zone(zone_name) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        Validator.validate_zone(zone)

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  @doc """
  Clone a zone for testing purposes.
  """
  @spec clone_zone(String.t() | Name.t(), String.t() | Name.t()) ::
          {:ok, Zone.t()} | {:error, String.t()}
  def clone_zone(source_zone_name, new_zone_name) do
    source_zone_name = normalize_zone_name(source_zone_name)
    new_zone_name = normalize_zone_name(new_zone_name)

    case Manager.get_zone(source_zone_name) do
      {:ok, source_zone} ->
        # Create new zone with same configuration
        new_zone = Zone.new(new_zone_name, source_zone.type)

        # Copy all records, updating names to new zone
        updated_zone = update_zone_names(source_zone, new_zone_name)

        # Create new zone
        Manager.create_zone(new_zone_name, new_zone.type, updated_zone.options)

      {:error, _reason} ->
        {:error, "Source zone not found: #{source_zone_name}"}
    end
  end

  @doc """
  Export zone to standard format.
  """
  @spec export_zone(String.t() | Name.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def export_zone(zone_name, options \\ []) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        format = Keyword.get(options, :format, :bind)

        case format do
          :bind ->
            export_bind_format(zone)

          :json ->
            export_json_format(zone)

          :yaml ->
            export_yaml_format(zone)

          _ ->
            {:error, "Unsupported export format: #{format}"}
        end

      {:error, _reason} ->
        {:error, "Zone not found: #{zone_name}"}
    end
  end

  ## Private functions

  defp normalize_zone_name(name) when is_binary(name), do: String.downcase(name)
  defp normalize_zone_name(%Name{value: value}), do: String.downcase(value)

  defp valid_zone_name?(name) do
    # Basic zone name validation
    String.match?(name, ~r/^[a-zA-Z0-9.-]+$/)
  end

  defp add_initial_records(zone, options) do
    # Add SOA record if provided
    zone =
      if soa_options = Keyword.get(options, :soa) do
        soa_record = create_soa_record(zone.name.value, soa_options)
        updated_options = Keyword.put(zone.options, :soa_records, [soa_record])
        %{zone | options: updated_options}
      else
        zone
      end

    # Add NS records if provided
    zone =
      if ns_names = Keyword.get(options, :ns) do
        ns_records =
          Enum.map(ns_names, fn ns_name ->
            Record.new(zone.name.value, :ns, :in, 3600, ns_name)
          end)

        updated_options = Keyword.put(zone.options, :ns_records, ns_records)
        %{zone | options: updated_options}
      else
        zone
      end

    zone
  end

  defp create_record(zone_name, record_type, options) do
    name = Keyword.get(options, :name, zone_name)
    ttl = Keyword.get(options, :ttl, 3600)
    class = Keyword.get(options, :class, :in)

    data =
      case record_type do
        :a ->
          Keyword.get(options, :ip, {192, 168, 1, 1})

        :aaaa ->
          Keyword.get(
            options,
            :ip,
            {0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334}
          )

        :cname ->
          Keyword.get(options, :target, zone_name)

        :ns ->
          Keyword.get(options, :nsdname, "ns1.#{zone_name}")

        :mx ->
          {Keyword.get(options, :preference, 10),
           Keyword.get(options, :exchange, "mail.#{zone_name}")}

        :txt ->
          Keyword.get(options, :text, "Sample text record")

        :soa ->
          create_soa_data(options)

        _ ->
          Keyword.get(options, :data, "sample data")
      end

    Record.new(name, record_type, class, ttl, data)
  end

  defp create_soa_record(zone_name, options) do
    data = create_soa_data(options)
    Record.new(zone_name, :soa, :in, 3600, data)
  end

  defp create_soa_data(options) do
    {
      Keyword.get(options, :mname, "ns1.example.com"),
      Keyword.get(options, :rname, "admin.example.com"),
      Keyword.get(options, :serial, 1),
      Keyword.get(options, :refresh, 3600),
      Keyword.get(options, :retry, 1800),
      Keyword.get(options, :expire, 604_800),
      Keyword.get(options, :minimum, 300)
    }
  end

  defp find_and_remove_records(records, options) do
    name = Keyword.get(options, :name)

    {matching, remaining} =
      if name do
        Enum.split_with(records, fn record ->
          record.name.value == name
        end)
      else
        {[], records}
      end

    {matching, remaining}
  end

  defp update_matching_records(records, match_options, update_options) do
    updated_records =
      Enum.map(records, fn record ->
        if match_record?(record, match_options) do
          update_record_data(record, update_options)
        else
          record
        end
      end)

    count =
      Enum.count(updated_records, fn record ->
        match_record?(record, match_options)
      end)

    {updated_records, count}
  end

  defp match_record?(record, options) do
    Enum.all?(options, fn {key, value} ->
      case key do
        :name -> record.name.value == value
        :type -> record.type == value
        :ttl -> record.ttl == value
        :class -> record.class == value
        # Ignore unknown keys
        _ -> true
      end
    end)
  end

  defp update_record_data(record, options) do
    updated_record = record

    # Update TTL if provided
    updated_record =
      if Keyword.has_key?(options, :ttl) do
        %{updated_record | ttl: Keyword.get(options, :ttl)}
      else
        updated_record
      end

    # Update data if provided (simplified)
    updated_record
  end

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

  defp format_record_data(record) do
    case record.type do
      :a ->
        record.data |> Tuple.to_list() |> Enum.join(".")

      :aaaa ->
        record.data |> Tuple.to_list() |> Enum.map(&Integer.to_string(&1, 16)) |> Enum.join(":")

      :cname ->
        record.data

      :ns ->
        record.data

      :mx ->
        {priority, exchange} = record.data
        "#{priority} #{exchange}"

      :txt ->
        record.data

      :soa ->
        {mname, rname, serial, refresh, retry, expire, minimum} = record.data
        "#{mname} #{rname} #{serial} #{refresh} #{retry} #{expire} #{minimum}"

      _ ->
        inspect(record.data)
    end
  end

  defp update_zone_names(source_zone, _new_zone_name) do
    # Update all record names to use new zone name
    # This is a simplified implementation
    source_zone
  end

  defp export_bind_format(zone) do
    records = get_all_records(zone)

    content = [
      "; Zone file for #{zone.name.value}",
      "; Generated on #{DateTime.utc_now()}",
      "",
      "$TTL 3600",
      "$ORIGIN #{zone.name.value}.",
      ""
    ]

    # Sort records by type and name
    sorted_records = Enum.sort_by(records, [& &1.type, & &1.name.value])

    # Group by type
    by_type = Enum.group_by(sorted_records, & &1.type)

    content =
      Enum.reduce(by_type, content, fn {type, records}, acc ->
        acc ++
          [
            "; #{String.upcase(to_string(type))} records",
            Enum.map(records, &record_to_bind_line/1),
            ""
          ]
      end)

    {:ok, Enum.join(content, "\n")}
  end

  defp export_json_format(zone) do
    records = get_all_records(zone)

    data = %{
      zone: zone.name.value,
      type: zone.type,
      records:
        Enum.map(records, fn record ->
          %{
            name: record.name.value,
            type: to_string(record.type),
            class: to_string(record.class),
            ttl: record.ttl,
            data: format_record_data_for_export(record)
          }
        end)
    }

    {:ok, Jason.encode!(data, pretty: true)}
  end

  defp export_yaml_format(zone) do
    records = get_all_records(zone)

    yaml = [
      "zone: #{zone.name.value}",
      "type: #{zone.type}",
      "records:"
    ]

    yaml =
      Enum.reduce(records, yaml, fn record, acc ->
        acc ++
          [
            "  - name: #{record.name.value}",
            "    type: #{record.type}",
            "    class: #{record.class}",
            "    ttl: #{record.ttl}",
            "    data: #{inspect(record.data)}"
          ]
      end)

    {:ok, Enum.join(yaml, "\n")}
  end

  defp record_to_bind_line(record) do
    name = if record.name.value == record.zone_name.value, do: "@", else: record.name.value

    "#{name} #{record.ttl} IN #{String.upcase(to_string(record.type))} #{format_record_data(record)}"
  end

  defp format_record_data_for_export(record) do
    type_str = to_string(record.type)

    cond do
      type_str == "A" ->
        record.data.data |> Tuple.to_list() |> Enum.join(".")

      type_str == "AAAA" ->
        record.data.data
        |> Tuple.to_list()
        |> Enum.map(&Integer.to_string(&1, 16))
        |> Enum.join(":")

      type_str == "CNAME" ->
        to_string(record.data.data)

      type_str == "NS" ->
        to_string(record.data.data)

      type_str == "MX" ->
        {priority, exchange} = record.data.data
        "#{priority} #{exchange}"

      type_str == "TXT" ->
        to_string(record.data.data)

      type_str == "SOA" ->
        {mname, rname, serial, refresh, retry, expire, minimum} = record.data.data
        "#{mname} #{rname} #{serial} #{refresh} #{retry} #{expire} #{minimum}"

      true ->
        inspect(record.data.data)
    end
  end
end
