defmodule YellowDog.Dns.View.ZoneManager do
  use Supervisor
  require Logger

  alias DNS.Zone.Manager, as: DNSZoneManager
  alias YellowDog.Config

  def lookup(pid, name, type) do
    zone_pid =
      pid
      |> child("supervisor")
      |> YellowDog.Dns.View.ZoneSupervisor.match_name(name)

    case zone_pid do
      nil ->
        {:nxdomain, []}

      zone_pid when is_pid(zone_pid) ->
        YellowDog.Dns.View.ZoneProcess.lookup(zone_pid, name, type)
    end
  end

  def child(pid, id) do
    pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn {child_id, pid, _, _} ->
      if child_id == id and is_pid(pid) do
        pid
      else
        false
      end
    end)
  end

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config)
  end

  def init(%{recursive: recursive} = _config) do
    _manager_pid = self()

    children = [
      Supervisor.child_spec({YellowDog.Dns.View.ZoneSupervisor, []},
        id: "supervisor"
      ),
      Supervisor.child_spec({YellowDog.Dns.View.ZoneRegistry, %{}},
        id: "registry"
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           # Load zones from configuration
           load_zones_from_config()

           if recursive do
             # TODO: Implement recursive zone functionality
           end
         end},
        id: "zone_loader_task"
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Load zones from YellowDog configuration
  defp load_zones_from_config do
    zones = Config.get_dns_zones()
    Logger.info("Loading #{map_size(zones)} DNS zones from configuration")

    Enum.each(zones, fn {zone_name, zone_config} ->
      case load_zone_from_config(zone_name, zone_config) do
        {:ok, zone} ->
          Logger.info("Successfully loaded zone: #{zone_name}")
          start_zone_process(zone)

        {:error, reason} ->
          Logger.error("Failed to load zone #{zone_name}: #{inspect(reason)}")
      end
    end)
  end

  # Load a single zone from configuration
  defp load_zone_from_config(zone_name, zone_config) do
    case Config.get_dns_zone_type(zone_name) do
      {:ok, zone_type} ->
        case Config.get_dns_zone_file(zone_name) do
          {:ok, zone_file_path} ->
            # Load zone from file
            case DNSZoneManager.load_zone_from_file(zone_name, zone_file_path) do
              {:ok, zone} ->
                # Update zone type if needed
                updated_zone = %{zone | type: zone_type}
                {:ok, updated_zone}

              {:error, reason} ->
                Logger.error("Failed to load zone file #{zone_file_path}: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, :not_found} ->
            # Create empty zone if no file specified
            Logger.warning("No zone file specified for #{zone_name}, creating empty zone")
            zone = DNSZoneManager.create_zone(zone_name, zone_type)
            zone

          {:error, reason} ->
            Logger.error("Error getting zone file for #{zone_name}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Error getting zone type for #{zone_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Start a zone process for a loaded zone
  defp start_zone_process(zone) do
    supervisor_pid = child(self(), "supervisor")

    case YellowDog.Dns.View.ZoneSupervisor.start_zone(supervisor_pid, zone) do
      {:ok, _pid} ->
        Logger.debug("Started zone process for #{zone.name.value}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start zone process for #{zone.name.value}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
