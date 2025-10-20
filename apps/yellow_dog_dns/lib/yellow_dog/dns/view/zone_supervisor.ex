defmodule YellowDog.Dns.View.ZoneSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(config) do
    DynamicSupervisor.start_link(__MODULE__, config)
  end

  def init(_config) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_zone(pid, zone) do
    DynamicSupervisor.start_child(
      pid,
      Supervisor.child_spec(
        {YellowDog.Dns.View.ZoneProcess, %{zone: zone, manager: self()}},
        id: zone.name
      )
    )
  end

  def start_zone(pid, zone, options) do
    DynamicSupervisor.start_child(
      pid,
      Supervisor.child_spec(
        {YellowDog.Dns.View.ZoneProcess, %{zone: zone, options: options, manager: self()}},
        id: zone.name
      )
    )
  end

  def terminate_zone(pid, zone) do
    DynamicSupervisor.which_children(pid)
    |> Enum.find(fn {id, pid, _type, _modules} ->
      if id == zone.name and is_pid(pid) do
        :ok = DynamicSupervisor.terminate_child(pid, id)
        true
      else
        false
      end
    end)
  end

  def match_name(nil, _name), do: nil

  def match_name(pid, query_name) do
    children = DynamicSupervisor.which_children(pid)

    # Find the most specific zone that matches the query name
    matching_zones =
      children
      |> Enum.filter(fn {zone_name, _zone_pid, _type, _modules} ->
        is_binary(zone_name) and zone_matches_query?(zone_name, query_name)
      end)
      |> Enum.sort_by(fn {zone_name, _pid, _type, _modules} ->
        # Sort by zone name length (longer = more specific)
        -String.length(zone_name)
      end)

    case matching_zones do
      [] ->
        Logger.debug("No zone found for query: #{query_name}")
        nil

      [{_zone_name, zone_pid, _type, _modules} | _] ->
        Logger.debug("Found zone #{elem(hd(matching_zones), 0)} for query #{query_name}")
        zone_pid
    end
  end

  # Check if a zone name matches a query name
  defp zone_matches_query?(zone_name, query_name) do
    # Normalize both names (ensure they end with .)
    normalized_zone = normalize_zone_name(zone_name)
    normalized_query = normalize_zone_name(query_name)

    # Check if query name is within the zone
    String.ends_with?(normalized_query, normalized_zone)
  end

  # Normalize zone name (ensure it ends with .)
  defp normalize_zone_name(name) do
    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end
end
