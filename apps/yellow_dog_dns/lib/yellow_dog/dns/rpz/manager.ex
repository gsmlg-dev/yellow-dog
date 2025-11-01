defmodule YellowDog.Dns.RPZ.Manager do
  @moduledoc """
  Manages Response Policy Zones (RPZ) with priority ordering and statistics.

  The RPZ Manager handles:
  - Loading and unloading RPZ zones
  - Priority ordering of multiple RPZ zones
  - Statistics tracking (blocks, rewrites, passthrus)
  - Configuration management

  ## Configuration

  RPZ zones can be configured via TOML:

      [dns.rpz]
      enabled = true

      [[dns.rpz.zones]]
      name = "malware-block.rpz"
      priority = 1
      file = "/etc/yellowdog/rpz/malware.zone"

      [[dns.rpz.zones]]
      name = "ads-block.rpz"
      priority = 2
      file = "/etc/yellowdog/rpz/ads.zone"

  Lower priority numbers are checked first.
  """

  use GenServer
  require Logger

  alias YellowDog.Dns.RPZ
  alias YellowDog.Dns.Zone.Manager, as: ZoneManager

  defmodule State do
    @moduledoc false
    defstruct [
      :zones,
      # Map of zone_name => priority
      :enabled,
      :stats
    ]

    @type t :: %__MODULE__{
            zones: %{String.t() => non_neg_integer()},
            enabled: boolean(),
            stats: map()
          }
  end

  # Client API

  @doc """
  Starts the RPZ Manager.

  ## Options
  - `:enabled` - Enable/disable RPZ (default: true)
  - `:zones` - List of RPZ zone configurations
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds an RPZ zone with priority.

  ## Parameters
  - `zone_name` - Name of the RPZ zone
  - `priority` - Priority (lower = higher priority)

  ## Returns
  `:ok` or `{:error, reason}`
  """
  @spec add_zone(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def add_zone(zone_name, priority) do
    GenServer.call(__MODULE__, {:add_zone, zone_name, priority})
  end

  @doc """
  Removes an RPZ zone.

  ## Parameters
  - `zone_name` - Name of the RPZ zone

  ## Returns
  `:ok` or `{:error, :not_found}`
  """
  @spec remove_zone(String.t()) :: :ok | {:error, :not_found}
  def remove_zone(zone_name) do
    GenServer.call(__MODULE__, {:remove_zone, zone_name})
  end

  @doc """
  Gets ordered list of RPZ zones (by priority).

  ## Returns
  List of zone names in priority order
  """
  @spec get_zones() :: [String.t()]
  def get_zones do
    GenServer.call(__MODULE__, :get_zones)
  end

  @doc """
  Checks a query against RPZ policies.

  ## Parameters
  - `qname` - Query name
  - `qtype` - Query type
  - `client_ip` - Client IP address

  ## Returns
  RPZ policy result
  """
  @spec check_policy(String.t(), atom(), tuple()) :: RPZ.policy_result()
  def check_policy(qname, qtype, client_ip) do
    GenServer.call(__MODULE__, {:check_policy, qname, qtype, client_ip})
  end

  @doc """
  Gets RPZ statistics.

  ## Returns
  Map with statistics:
  - `:total_queries` - Total queries checked
  - `:blocks` - Queries blocked
  - `:rewrites` - Queries rewritten
  - `:passthrus` - Queries passed through
  - `:by_action` - Breakdown by action type
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Enables or disables RPZ.

  ## Parameters
  - `enabled` - true to enable, false to disable
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  @doc """
  Checks if RPZ is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    zone_configs = Keyword.get(opts, :zones, [])

    # Load configured RPZ zones
    zones =
      Enum.reduce(zone_configs, %{}, fn config, acc ->
        zone_name = Keyword.get(config, :name)
        priority = Keyword.get(config, :priority, 100)

        if zone_name do
          Map.put(acc, zone_name, priority)
        else
          acc
        end
      end)

    stats = %{
      total_queries: 0,
      blocks: 0,
      rewrites: 0,
      passthrus: 0,
      by_action: %{
        nxdomain: 0,
        nodata: 0,
        drop: 0,
        tcp_only: 0,
        local_data: 0,
        passthru: 0
      }
    }

    state = %State{
      zones: zones,
      enabled: enabled,
      stats: stats
    }

    Logger.info("RPZ Manager initialized",
      enabled: enabled,
      zone_count: map_size(zones)
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:add_zone, zone_name, priority}, _from, state) do
    new_zones = Map.put(state.zones, zone_name, priority)
    new_state = %{state | zones: new_zones}

    Logger.info("Added RPZ zone", zone: zone_name, priority: priority)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_zone, zone_name}, _from, state) do
    case Map.pop(state.zones, zone_name) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_priority, new_zones} ->
        new_state = %{state | zones: new_zones}
        Logger.info("Removed RPZ zone", zone: zone_name)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:get_zones, _from, state) do
    # Sort zones by priority (lower number = higher priority)
    sorted_zones =
      state.zones
      |> Enum.sort_by(fn {_name, priority} -> priority end)
      |> Enum.map(fn {name, _priority} -> name end)

    {:reply, sorted_zones, state}
  end

  @impl true
  def handle_call({:check_policy, qname, qtype, client_ip}, _from, state) do
    if state.enabled do
      zones = get_zones_list(state)

      result = RPZ.check_policy(qname, qtype, client_ip, rpz_zones: zones)

      # Update statistics
      new_stats = update_stats(state.stats, result)
      new_state = %{state | stats: new_stats}

      {:reply, result, new_state}
    else
      {:reply, :passthru, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    new_state = %{state | enabled: enabled}
    Logger.info("RPZ enabled status changed", enabled: enabled)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  # Private functions

  defp get_zones_list(state) do
    state.zones
    |> Enum.sort_by(fn {_name, priority} -> priority end)
    |> Enum.map(fn {name, _priority} -> name end)
  end

  defp update_stats(stats, result) do
    stats = Map.update!(stats, :total_queries, &(&1 + 1))

    case result do
      {:block, action, _} ->
        stats
        |> Map.update!(:blocks, &(&1 + 1))
        |> update_in([:by_action, action], &((&1 || 0) + 1))

      {:rewrite, _, _} ->
        stats
        |> Map.update!(:rewrites, &(&1 + 1))
        |> update_in([:by_action, :local_data], &((&1 || 0) + 1))

      :passthru ->
        stats
        |> Map.update!(:passthrus, &(&1 + 1))
        |> update_in([:by_action, :passthru], &((&1 || 0) + 1))

      {:passthru, _} ->
        stats
        |> Map.update!(:passthrus, &(&1 + 1))
        |> update_in([:by_action, :passthru], &((&1 || 0) + 1))
    end
  end
end
