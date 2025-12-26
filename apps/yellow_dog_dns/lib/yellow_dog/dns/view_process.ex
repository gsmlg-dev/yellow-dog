defmodule YellowDog.Dns.ViewProcess do
  @moduledoc """
  View process for handling DNS queries.

  Each view is a GenServer that:
  - Matches client IPs against its ACL
  - Routes queries to appropriate zones
  - Manages view-local cache
  - Handles recursive resolution (via RecursionController)

  ## Resolution Flow

  1. Check view-local cache
  2. Find matching zone for query
  3. Route to zone process for resolution
  4. Cache the response
  5. Return response to caller
  """

  use GenServer

  alias YellowDog.Telemetry
  alias YellowDog.Dns.TSI
  alias YellowDog.Dns.View.ACL
  alias YellowDog.Dns.ZoneController
  alias DNS.Message

  @default_cache_size 1000

  defstruct [
    :name,
    :acl,
    :zones,
    :cache_table,
    :recursion_enabled,
    :recursion_controller,
    query_count: 0,
    hit_count: 0,
    miss_count: 0
  ]

  # Client API

  @doc """
  Starts a view process.

  ## Options

  - `:name` - View name (required)
  - `:acl` - ACL for client matching (default: `:all`)
  - `:zones` - List of zone names or zone configurations
  - `:recursion_enabled` - Enable recursive resolution (default: true)
  - `:cache_size` - Maximum cache entries (default: 1000)
  """
  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = normalize_opts(opts)
    view_name = Map.fetch!(config, :name)
    GenServer.start_link(__MODULE__, config, name: via_tuple(view_name))
  end

  @doc """
  Checks if a client IP matches this view's ACL.
  """
  @spec matches?(pid(), :inet.ip_address()) :: boolean()
  def matches?(pid, client_ip) do
    GenServer.call(pid, {:matches?, client_ip})
  end

  @doc """
  Resolves a DNS query within this view.
  """
  @spec resolve(pid(), TSI.t()) :: {:ok, Message.t()} | {:error, atom()}
  def resolve(pid, tsi) do
    GenServer.call(pid, {:resolve, tsi})
  end

  @doc """
  Reloads view configuration.
  """
  @spec reload(pid(), map() | keyword()) :: :ok
  def reload(pid, config) do
    GenServer.call(pid, {:reload, config})
  end

  @doc """
  Returns view statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Gets the view name.
  """
  @spec get_name(pid()) :: String.t()
  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  # Server Callbacks

  @impl true
  def init(config) do
    view_name = Map.fetch!(config, :name)
    acl = parse_acl(Map.get(config, :acl, :all))
    zones = Map.get(config, :zones, [])
    recursion_enabled = Map.get(config, :recursion_enabled, true)
    _cache_size = Map.get(config, :cache_size, @default_cache_size)

    # Create view-local cache
    cache_table =
      :ets.new(:"view_cache_#{view_name}", [
        :set,
        :protected,
        read_concurrency: true
      ])

    state = %__MODULE__{
      name: view_name,
      acl: acl,
      zones: zones,
      cache_table: cache_table,
      recursion_enabled: recursion_enabled
    }

    Telemetry.info("View process started", %{
      name: view_name,
      zones: zones,
      recursion: recursion_enabled
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call({:matches?, client_ip}, _from, state) do
    result = acl_matches?(state.acl, client_ip)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:resolve, tsi}, _from, state) do
    state = %{state | query_count: state.query_count + 1}

    # Update TSI with view name
    tsi = TSI.set_view(tsi, state.name)

    case do_resolve(state, tsi) do
      {:ok, _response} = result ->
        state = %{state | hit_count: state.hit_count + 1}
        {:reply, result, state}

      {:error, _} = error ->
        state = %{state | miss_count: state.miss_count + 1}
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    config = normalize_opts(config)

    new_state = %{
      state
      | acl: parse_acl(Map.get(config, :acl, state.acl)),
        zones: Map.get(config, :zones, state.zones),
        recursion_enabled: Map.get(config, :recursion_enabled, state.recursion_enabled)
    }

    Telemetry.info("View reloaded", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(state.cache_table, :size)

    stats = %{
      name: state.name,
      zones: state.zones,
      recursion_enabled: state.recursion_enabled,
      query_count: state.query_count,
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      cache_size: cache_size
    }

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.cache_table)
    :ok
  end

  # Private Functions

  defp do_resolve(state, tsi) do
    query = tsi.query

    case query.questions do
      [question | _] ->
        # Check view-local cache first
        case check_cache(state, question.name, question.type) do
          {:ok, cached_response} ->
            response = update_response_id(cached_response, query.header.id)
            {:ok, response}

          :miss ->
            # Find zone and resolve
            resolve_query(state, tsi, question)
        end

      [] ->
        {:error, :format_error}
    end
  end

  defp resolve_query(state, tsi, question) do
    zone_name = find_zone_for_name(state.zones, question.name)

    if zone_name do
      tsi = TSI.set_zone(tsi, zone_name)
      resolve_in_zone(state, tsi, zone_name)
    else
      # No matching zone - try recursion if enabled
      if state.recursion_enabled do
        perform_recursion(state, tsi)
      else
        {:error, :refused}
      end
    end
  end

  defp resolve_in_zone(state, tsi, zone_name) do
    # Try different zone types in order
    zone_types = [:auth, :forward, :stub]

    result =
      Enum.find_value(zone_types, fn zone_type ->
        case ZoneController.find_zone(zone_type, zone_name) do
          {:ok, zone_pid} ->
            module = zone_module(zone_type)

            case module.resolve(zone_pid, tsi, tsi.query) do
              {:ok, response} = result ->
                # Cache the response
                cache_response(state, tsi.query, response)
                result

              {:referral, _ns_records} ->
                # Handle referral - for now, treat as not found
                nil

              {:error, :refused} ->
                # This zone refused, try next type
                nil

              {:error, _} = error ->
                error
            end

          :error ->
            nil
        end
      end)

    case result do
      nil ->
        # No zone could resolve - try recursion if enabled
        if state.recursion_enabled do
          perform_recursion(state, tsi)
        else
          {:error, :refused}
        end

      result ->
        result
    end
  end

  defp perform_recursion(_state, tsi) do
    # For now, try the forward zone "." (root)
    case ZoneController.find_zone(:forward, ".") do
      {:ok, zone_pid} ->
        YellowDog.Dns.Zone.Forward.resolve(zone_pid, tsi, tsi.query)

      :error ->
        # No forwarding configured
        {:error, :servfail}
    end
  end

  defp find_zone_for_name(zones, query_name) do
    normalized = normalize_name(query_name)

    # Find the most specific matching zone
    Enum.find(zones, fn zone_name ->
      zone_suffix = normalize_name(zone_name)
      String.ends_with?(normalized, zone_suffix) or normalized == zone_suffix
    end)
  end

  defp check_cache(state, name, type) do
    key = {normalize_name(name), type}

    case :ets.lookup(state.cache_table, key) do
      [{^key, {response, expires_at}}] ->
        if expires_at > System.system_time(:second) do
          {:ok, response}
        else
          :ets.delete(state.cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_response(state, query, response) do
    case query.questions do
      [question | _] ->
        ttl = get_min_ttl(response)
        key = {normalize_name(question.name), question.type}
        expires_at = System.system_time(:second) + ttl
        :ets.insert(state.cache_table, {key, {response, expires_at}})

      [] ->
        :ok
    end
  end

  defp get_min_ttl(response) do
    all_records = response.answers ++ response.authority ++ response.additional

    case all_records do
      [] -> 300
      records -> Enum.map(records, & &1.ttl) |> Enum.min() |> max(60)
    end
  end

  defp update_response_id(response, new_id) do
    %{response | header: %{response.header | id: new_id}}
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp parse_acl(:all), do: :all

  defp parse_acl(acl_name) when is_binary(acl_name) do
    {:named, acl_name}
  end

  defp parse_acl(%ACL{} = acl), do: acl

  defp parse_acl(rules) when is_list(rules) do
    ACL.new("inline", rules)
  end

  defp parse_acl(_), do: :all

  defp acl_matches?(:all, _client_ip), do: true

  defp acl_matches?({:named, acl_name}, client_ip) do
    ACL.matches?(acl_name, client_ip)
  end

  defp acl_matches?(%ACL{} = acl, client_ip) do
    ACL.matches?(acl, client_ip)
  end

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)

  defp via_tuple(view_name) do
    {:via, Registry, {YellowDog.Dns.ViewRegistry, view_name}}
  end
end
