defmodule YellowDog.Dns.View.ZoneProcess do
  use GenServer
  require Logger

  alias DNS.Zone.Editor
  alias DNS.Message.Record
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Class

  def lookup(pid, name, type) do
    GenServer.call(pid, {:lookup, name, type})
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(%{zone: zone, options: options, manager: manager}) do
    Logger.debug("Starting ZoneProcess for zone: #{zone.name.value} (type: #{zone.type})")
    {:ok, %{zone: zone, options: options, manager: manager}}
  end

  def handle_call({:lookup, name, type}, _from, %{zone: zone} = state) do
    Logger.debug("ZoneProcess lookup: #{name} #{type} in zone #{zone.name.value}")

    result =
      case zone.type do
        :authoritative ->
          lookup_authoritative(zone, name, type)

        :stub ->
          lookup_stub(zone, name, type)

        :forward ->
          lookup_forward(zone, name, type)

        _ ->
          lookup_default(zone, name, type)
      end

    {:reply, result, state}
  end

  defp lookup_authoritative(zone, name, type) do
    # Use DNS.Zone.Editor to search for records in the zone
    case Editor.search_records(zone.name.value, name: name, type: type) do
      {:ok, []} ->
        # No records found - return NXDOMAIN
        {:nxdomain, []}

      {:ok, zone_records} ->
        # Convert zone records to DNS.Message.Record format
        dns_records = convert_zone_records_to_dns_records(zone_records)
        {:ok, dns_records}

      {:error, reason} ->
        Logger.warning("Zone lookup error for #{name} #{type} in #{zone.name.value}: #{reason}")
        {:servfail, []}
    end
  end

  defp lookup_stub(zone, name, type) do
    # Stub zones only contain NS records for delegation
    case type do
      :ns ->
        lookup_authoritative(zone, name, type)

      _ ->
        # For non-NS queries in stub zones, delegate to authoritative servers
        # For now, return servfail - this could be enhanced to do recursion
        {:servfail, []}
    end
  end

  defp lookup_forward(zone, name, type) do
    # Forward zones redirect queries to specified servers
    # For now, we'll implement a basic forwarder that could be enhanced later
    Logger.debug("Forward zone lookup not yet implemented for #{zone.name.value}")
    {:servfail, []}
  end

  defp lookup_default(zone, name, type) do
    Logger.warning("Unknown zone type #{zone.type} for #{zone.name.value}")
    {:servfail, []}
  end

  # Convert zone records from DNS.Zone format to DNS.Message.Record format
  defp convert_zone_records_to_dns_records(zone_records) do
    Enum.map(zone_records, fn zone_record ->
      # Convert the zone record format to DNS.Message.Record
      # zone_record has: %{name: name, type: type, class: class, ttl: ttl, data: data}

      Record.new(
        zone_record.name,
        zone_record.type,
        zone_record.class,
        zone_record.ttl,
        zone_record.data
      )
    end)
  end
end
