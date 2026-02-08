defmodule DNS.Zone.Transfer do
  @moduledoc """
  Zone transfer functionality for DNS zones (AXFR/IXFR).

  Provides full zone transfer (AXFR) and incremental zone transfer (IXFR)
  capabilities according to RFC 1995 and RFC 5936.
  """

  alias DNS.Zone
  alias DNS.Zone.Name
  alias DNS.Message.Record
  alias DNS.Zone.Manager


  @doc """
  Perform full zone transfer (AXFR) for a zone.
  """
  @spec axfr(String.t() | Name.t()) :: {:ok, list(Record.t())} | {:error, String.t()}
  def axfr(zone_name) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        # Get all records from the zone
        records = get_zone_records(zone)
        {:ok, records}

      {:error, :not_found} ->
        zone_not_found(zone_name)

      {:error, reason} ->
        {:error, "AXFR failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Perform incremental zone transfer (IXFR) for a zone.
  """
  @spec ixfr(String.t() | Name.t(), integer() | DateTime.t()) ::
          {:ok, list(Record.t())} | {:error, String.t()}
  def ixfr(zone_name, serial) when is_integer(serial) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        current_serial = get_zone_serial(zone)

        if serial >= current_serial do
          # No changes needed
          {:ok, []}
        else
          # TODO: Implement incremental change detection
          # For now, fall back to full transfer
          axfr(zone_name)
        end

      {:error, :not_found} ->
        zone_not_found(zone_name)

      {:error, reason} ->
        {:error, "IXFR failed: #{inspect(reason)}"}
    end
  end

  def ixfr(zone_name, %DateTime{} = since) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        last_modified = get_zone_last_modified(zone)

        if DateTime.after?(since, last_modified) do
          # No changes since the requested time
          {:ok, []}
        else
          # TODO: Implement incremental change detection
          # For now, fall back to full transfer
          axfr(zone_name)
        end

      {:error, :not_found} ->
        zone_not_found(zone_name)

      {:error, reason} ->
        {:error, "IXFR failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Validate if zone transfer is allowed for the requesting client.
  """
  @spec transfer_allowed?(String.t() | Name.t(), :inet.ip_address()) :: boolean()
  def transfer_allowed?(zone_name, client_ip) do
    zone_name = normalize_zone_name(zone_name)

    case Manager.get_zone(zone_name) do
      {:ok, zone} ->
        allow_transfer = Keyword.get(zone.options, :allow_transfer, [])

        cond do
          allow_transfer == :any ->
            true

          allow_transfer == :none ->
            false

          is_list(allow_transfer) ->
            Enum.any?(allow_transfer, &ip_matches?(&1, client_ip))

          true ->
            false
        end

      {:error, _} ->
        false
    end
  end

  @doc """
  Create zone transfer response message.
  """
  @spec create_transfer_response(String.t() | Name.t(), list(Record.t()), :axfr | :ixfr) ::
          {:ok, map()} | {:error, String.t()}
  def create_transfer_response(zone_name, records, transfer_type) do
    zone_name = normalize_zone_name(zone_name)

    if records == [] do
      {:error, "No records to transfer"}
    else
      # Create transfer message structure
      response = %{
        zone_name: zone_name,
        transfer_type: transfer_type,
        records: records,
        serial: get_zone_serial_from_records(records),
        count: length(records),
        timestamp: DateTime.utc_now()
      }

      {:ok, response}
    end
  end

  @doc """
  Apply transferred zone data to local zone store.
  """
  @spec apply_transfer(String.t() | Name.t(), list(Record.t()), keyword()) ::
          {:ok, Zone.t()} | {:error, String.t()}
  def apply_transfer(zone_name, records, options \\ []) do
    zone_name = normalize_zone_name(zone_name)

    transfer_type = Keyword.get(options, :transfer_type, :axfr)

    case transfer_type do
      :axfr ->
        apply_axfr(zone_name, records, options)

      :ixfr ->
        apply_ixfr(zone_name, records, options)

      _ ->
        {:error, "Invalid transfer type: #{transfer_type}"}
    end
  end

  @doc """
  Create zone transfer request.
  """
  @spec create_transfer_request(String.t() | Name.t(), :axfr | :ixfr, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create_transfer_request(zone_name, transfer_type, options \\ []) do
    zone_name = normalize_zone_name(zone_name)

    request = %{
      zone_name: zone_name,
      transfer_type: transfer_type,
      serial: Keyword.get(options, :serial),
      since: Keyword.get(options, :since),
      client_ip: Keyword.get(options, :client_ip, {0, 0, 0, 0}),
      timestamp: DateTime.utc_now()
    }

    {:ok, request}
  end

  ## Private functions

  defp normalize_zone_name(name), do: DNS.Zone.normalize_zone_name(name)
  defp zone_not_found(zone_name), do: {:error, "Zone not found: #{zone_name}"}

  defp get_zone_records(zone), do: Zone.all_records(zone)

  defp get_zone_serial(zone) do
    case Keyword.get(zone.options, :soa_records, []) do
      [soa | _] ->
        case soa.data do
          %DNS.Message.Record.Data.SOA{data: data} ->
            {_mname, _rname, serial, _refresh, _retry, _expire, _minimum} = data
            serial

          data when is_tuple(data) ->
            {_mname, _rname, serial, _refresh, _retry, _expire, _minimum} = data
            serial
        end

      _ ->
        0
    end
  end

  defp get_zone_last_modified(zone) do
    # Default to zone creation time if no modification time available
    Keyword.get(zone.options, :last_modified, DateTime.utc_now())
  end

  defp get_zone_serial_from_records(records) do
    Enum.find_value(records, 0, fn record ->
      if record.type == :soa do
        {_mname, _rname, serial, _refresh, _retry, _expire, _minimum} = record.data
        serial
      else
        nil
      end
    end)
  end

  defp ip_matches?(allowed_ip, client_ip) when is_tuple(allowed_ip) and is_tuple(client_ip) do
    allowed_ip == client_ip
  end

  defp ip_matches?(allowed_subnet, client_ip) when is_binary(allowed_subnet) do
    # Simple subnet matching - TODO: Implement proper CIDR matching
    String.contains?(allowed_subnet, "/") == false and
      allowed_subnet == to_string(:inet_parse.ntoa(client_ip))
  end

  defp ip_matches?(_, _), do: false

  defp apply_axfr(zone_name, records, _options) do
    # Create new zone with transferred records
    zone = Zone.new(zone_name, :authoritative)

    # Update zone with transferred records
    updated_zone = update_zone_with_records(zone, records)

    # Create the zone (not update, since it might not exist)
    case Manager.create_zone(zone_name, :authoritative, updated_zone.options) do
      {:ok, zone} -> {:ok, zone}
      {:error, reason} -> {:error, "Failed to apply AXFR: #{inspect(reason)}"}
    end
  end

  defp apply_ixfr(_zone_name, _records, _options) do
    # TODO: Implement incremental zone update
    {:error, "IXFR application not yet implemented"}
  end

  defp update_zone_with_records(zone, records) do
    categorized = Enum.group_by(records, & &1.type)

    record_options =
      Enum.map(Zone.record_type_to_option_key(), fn {type, key} ->
        {key, Map.get(categorized, type, [])}
      end)

    %{zone | options: Keyword.merge(zone.options, record_options)}
  end
end
