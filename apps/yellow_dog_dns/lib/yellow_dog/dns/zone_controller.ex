defmodule YellowDog.Dns.ZoneController do
  @moduledoc """
  Supervisor for DNS zone processes.

  The ZoneController manages the lifecycle of zone processes:
  - Auth zones (authoritative data)
  - Forward zones (upstream forwarding)
  - Stub zones (NS delegation)
  - Root zone (root hints)
  - Cache zones (query caching)

  Zones can be dynamically added, removed, and reloaded.
  """

  use DynamicSupervisor

  alias YellowDog.Telemetry

  @doc """
  Starts the ZoneController supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Telemetry.info("ZoneController starting")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a zone process.

  ## Parameters

  - `zone_type` - Type of zone (:auth, :forward, :stub, :root, :cache)
  - `zone_name` - Name of the zone (e.g., "example.com")
  - `config` - Zone-specific configuration

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_zone(atom(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_zone(zone_type, zone_name, config \\ []) do
    start_zone(__MODULE__, zone_type, zone_name, config)
  end

  @spec start_zone(Supervisor.supervisor(), atom(), String.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_zone(supervisor, zone_type, zone_name, config) do
    module = zone_module(zone_type)
    opts = Keyword.merge(config, name: zone_name)

    # Add zone_data_path for auth zones to enable persistence
    opts =
      if zone_type == :auth do
        case get_zone_data_path() do
          nil -> opts
          path -> Keyword.put_new(opts, :zone_data_path, path)
        end
      else
        opts
      end

    child_spec = %{
      id: {zone_type, zone_name},
      start: {module, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} = result ->
        Telemetry.info("Zone started", %{type: zone_type, name: zone_name, pid: inspect(pid)})
        result

      {:error, reason} = error ->
        Telemetry.error("Failed to start zone", %{
          type: zone_type,
          name: zone_name,
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Stops a zone process.
  """
  @spec stop_zone(atom(), String.t()) :: :ok | {:error, :not_found}
  def stop_zone(zone_type, zone_name) do
    stop_zone(__MODULE__, zone_type, zone_name)
  end

  @spec stop_zone(Supervisor.supervisor(), atom(), String.t()) :: :ok | {:error, :not_found}
  def stop_zone(supervisor, zone_type, zone_name) do
    case find_zone(supervisor, zone_type, zone_name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(supervisor, pid)

        Telemetry.info("Zone stopped", %{type: zone_type, name: zone_name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Finds a zone process by type and name.
  """
  @spec find_zone(atom(), String.t()) :: {:ok, pid()} | :error
  def find_zone(zone_type, zone_name) do
    find_zone(__MODULE__, zone_type, zone_name)
  end

  @spec find_zone(Supervisor.supervisor(), atom(), String.t()) :: {:ok, pid()} | :error
  def find_zone(supervisor, zone_type, zone_name) do
    module = zone_module(zone_type)

    children = DynamicSupervisor.which_children(supervisor)

    case Enum.find(children, fn {id, _pid, _type, _modules} ->
           id == {zone_type, zone_name}
         end) do
      {_id, pid, _type, _modules} when is_pid(pid) -> {:ok, pid}
      _ -> find_by_module_and_name(children, module, zone_name)
    end
  end

  @doc """
  Lists all active zones.
  """
  @spec list_zones() :: [{atom(), String.t(), pid()}]
  def list_zones do
    list_zones(__MODULE__)
  end

  @spec list_zones(Supervisor.supervisor()) :: [{atom(), String.t(), pid()}]
  def list_zones(supervisor) do
    DynamicSupervisor.which_children(supervisor)
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> Enum.map(fn {{zone_type, zone_name}, pid, _type, _modules} ->
      {zone_type, zone_name, pid}
    end)
  end

  @doc """
  Reloads a zone with new configuration.
  """
  @spec reload_zone(atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def reload_zone(zone_type, zone_name, config) do
    reload_zone(__MODULE__, zone_type, zone_name, config)
  end

  @spec reload_zone(Supervisor.supervisor(), atom(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def reload_zone(supervisor, zone_type, zone_name, config) do
    case find_zone(supervisor, zone_type, zone_name) do
      {:ok, pid} ->
        module = zone_module(zone_type)
        module.reload(pid, config)

      :error ->
        {:error, :not_found}
    end
  end

  # Maps zone type atoms to module names
  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:root), do: YellowDog.Dns.Zone.Root
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache
  defp zone_module(:rpz), do: YellowDog.Dns.Zone.RPZ

  defp find_by_module_and_name(children, module, zone_name) do
    Enum.find_value(children, :error, fn {_id, pid, _type, modules} ->
      if is_pid(pid) and module in modules do
        # Check if this is the right zone by calling get_name
        try do
          if module.get_name(pid) == zone_name do
            {:ok, pid}
          else
            nil
          end
        catch
          _, _ -> nil
        end
      else
        nil
      end
    end)
  end

  # Get zone data path from config with fallback to default
  defp get_zone_data_path do
    try do
      apply(YellowDog.Config, :get, [:dns, :zone_data_path]) ||
        default_zone_data_path()
    rescue
      _ -> default_zone_data_path()
    end
  end

  defp default_zone_data_path do
    # Default to priv/zones directory
    case :code.priv_dir(:yellow_dog_dns) do
      {:error, _} -> "priv/zones"
      path -> Path.join(to_string(path), "zones")
    end
  end
end
