defmodule YellowDog.Dns.View do
  @moduledoc """
  Individual view process handling request routing and resolution strategy.

  Each view is a GenServer that:
  - Matches client IPs against its ACL
  - Routes queries to appropriate zones
  - Manages view-local cache
  - Handles recursive resolution (via RecursionController)
  - Applies RPZ policies (post-resolution filtering)

  ## State

  - ACL configuration (client IP / EDNS client subnet matching)
  - Zone references (registered zones, including dynamic cache zones)
  - RPZ references (ordered by specificity for post-resolution filtering)
  - Recursion enabled/disabled flag
  - ECS matching enabled/disabled flag

  ## Children (for recursive-enabled views)

  - `YellowDog.Dns.RecursionController` - Manages recursive resolution processes
  - Root Zone process (one per recursive-enabled view)

  ## Request Handling

  1. Receive request from connection process (via ViewManager, with PID)
  2. Notify connection process: view matched
  3. Determine resolution strategy (recursive enabled/disabled)
  4. Find matching zone, send request to zone (with connection process PID)
  5. Receive response from zone
  6. Notify connection process: zone response received
  7. Apply RPZ policies to response (post-resolution)
  8. Notify connection process: RPZ evaluation complete
  9. Send final response to connection process
  """

  use GenServer

  alias YellowDog.Telemetry
  alias YellowDog.Dns.View.ACL
  alias YellowDog.Dns.ZoneController
  alias DNS.Message

  @default_priority 100

  defstruct [
    :name,
    :priority,
    :acl,
    :zones,
    :rpz_zones,
    :cache_table,
    :recursion_enabled,
    :ecs_enabled,
    :recursion_controller,
    enabled: true,
    # Fallback forwarders: list of {ip_tuple, port} for when zone resolution fails
    fallback_forwarders: [],
    fallback_timeout: 2000,
    fallback_retries: 1,
    query_count: 0,
    hit_count: 0,
    miss_count: 0
  ]

  # Client API

  @doc """
  Starts a view process.

  ## Options

  - `:name` - View name (required)
  - `:priority` - Priority for matching (lower = higher priority, default: 100)
  - `:acl` - ACL for client matching (default: `:any`)
  - `:zones` - List of zone names or zone configurations
  - `:rpz_zones` - List of RPZ zone references (ordered by specificity)
  - `:recursion_enabled` - Enable recursive resolution (default: true)
  - `:ecs_enabled` - Enable EDNS client subnet matching (default: false)
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

  The connection_pid is used for sending async resolution notifications.
  """
  @spec resolve(pid(), pid(), non_neg_integer(), Message.t()) ::
          {:ok, Message.t()} | {:error, atom()}
  def resolve(pid, connection_pid, query_id, query) do
    GenServer.call(pid, {:resolve, connection_pid, query_id, query})
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

  @doc """
  Gets the view priority.
  """
  @spec get_priority(pid()) :: integer() | :infinity
  def get_priority(pid) do
    GenServer.call(pid, :get_priority)
  end

  @doc """
  Enables or disables this view.
  """
  @spec set_enabled(pid(), boolean()) :: :ok
  def set_enabled(pid, enabled) do
    GenServer.call(pid, {:set_enabled, enabled})
  end

  @doc """
  Returns whether this view is enabled.
  """
  @spec is_enabled?(pid()) :: boolean()
  def is_enabled?(pid) do
    GenServer.call(pid, :is_enabled?)
  end

  @doc """
  Registers a zone with this view.
  """
  @spec register_zone(pid(), atom(), String.t()) :: :ok
  def register_zone(pid, zone_type, zone_name) do
    GenServer.call(pid, {:register_zone, zone_type, zone_name})
  end

  @doc """
  Registers an RPZ zone with this view.
  """
  @spec register_rpz_zone(pid(), String.t()) :: :ok
  def register_rpz_zone(pid, rpz_name) do
    GenServer.call(pid, {:register_rpz_zone, rpz_name})
  end

  # Server Callbacks

  @impl true
  def init(config) do
    view_name = Map.fetch!(config, :name)
    priority = Map.get(config, :priority, @default_priority)
    acl = parse_acl(Map.get(config, :acl, :any))
    zones = Map.get(config, :zones, [])
    rpz_zones = Map.get(config, :rpz_zones, [])
    enabled = Map.get(config, :enabled, true)
    recursion_enabled = Map.get(config, :recursion_enabled, true)
    ecs_enabled = Map.get(config, :ecs_enabled, false)
    # Create view-local cache
    cache_table =
      :ets.new(:"view_cache_#{view_name}", [
        :set,
        :protected,
        read_concurrency: true
      ])

    fallback_forwarders = Map.get(config, :fallback_forwarders, [])
    fallback_timeout = Map.get(config, :fallback_timeout, 2000)
    fallback_retries = Map.get(config, :fallback_retries, 1)

    state = %__MODULE__{
      name: view_name,
      priority: priority,
      acl: acl,
      zones: zones,
      rpz_zones: rpz_zones,
      cache_table: cache_table,
      enabled: enabled,
      recursion_enabled: recursion_enabled,
      ecs_enabled: ecs_enabled,
      fallback_forwarders: fallback_forwarders,
      fallback_timeout: fallback_timeout,
      fallback_retries: fallback_retries
    }

    Telemetry.info("View process started", %{
      name: view_name,
      priority: priority,
      zones: zones,
      rpz_zones: rpz_zones,
      recursion: recursion_enabled,
      ecs: ecs_enabled
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call(:get_priority, _from, state) do
    {:reply, state.priority, state}
  end

  @impl true
  def handle_call({:matches?, client_ip}, _from, %{enabled: false} = state) do
    # Disabled views never match
    _ = client_ip
    {:reply, false, state}
  end

  @impl true
  def handle_call({:matches?, client_ip}, _from, state) do
    result = acl_matches?(state.acl, client_ip)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    Telemetry.info("View #{if enabled, do: "enabled", else: "disabled"}", %{name: state.name})
    {:reply, :ok, %{state | enabled: enabled}}
  end

  @impl true
  def handle_call(:is_enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def handle_call(
        {:resolve, _connection_pid, _query_id, _query},
        _from,
        %{enabled: false} = state
      ) do
    {:reply, {:error, :disabled}, state}
  end

  @impl true
  def handle_call({:resolve, connection_pid, query_id, query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}

    case do_resolve(state, connection_pid, query_id, query) do
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
      | priority: Map.get(config, :priority, state.priority),
        acl: parse_acl(Map.get(config, :acl, state.acl)),
        zones: Map.get(config, :zones, state.zones),
        rpz_zones: Map.get(config, :rpz_zones, state.rpz_zones),
        enabled: Map.get(config, :enabled, state.enabled),
        recursion_enabled: Map.get(config, :recursion_enabled, state.recursion_enabled),
        ecs_enabled: Map.get(config, :ecs_enabled, state.ecs_enabled),
        fallback_forwarders: Map.get(config, :fallback_forwarders, state.fallback_forwarders),
        fallback_timeout: Map.get(config, :fallback_timeout, state.fallback_timeout),
        fallback_retries: Map.get(config, :fallback_retries, state.fallback_retries)
    }

    Telemetry.info("View reloaded", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:register_zone, zone_type, zone_name}, _from, state) do
    # Add the {type, name} tuple and remove any plain string entry for the same zone name
    # (persisted config may store zone names as strings without type information)
    zones =
      [{zone_type, zone_name} | state.zones]
      |> Enum.reject(fn
        name when is_binary(name) -> name == zone_name
        _ -> false
      end)
      |> Enum.uniq()

    {:reply, :ok, %{state | zones: zones}}
  end

  @impl true
  def handle_call({:register_rpz_zone, rpz_name}, _from, state) do
    rpz_zones = [rpz_name | state.rpz_zones] |> Enum.uniq()
    {:reply, :ok, %{state | rpz_zones: rpz_zones}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(state.cache_table, :size)

    stats = %{
      name: state.name,
      priority: state.priority,
      enabled: state.enabled,
      zones: state.zones,
      rpz_zones: state.rpz_zones,
      recursion_enabled: state.recursion_enabled,
      ecs_enabled: state.ecs_enabled,
      fallback_forwarders: state.fallback_forwarders,
      fallback_timeout: state.fallback_timeout,
      fallback_retries: state.fallback_retries,
      query_count: state.query_count,
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      cache_size: cache_size
    }

    {:reply, stats, state}
  end

  # Handle cancel query message from connection process
  @impl true
  def handle_info({:cancel_query, _query_id}, state) do
    # TODO: Cancel in-flight resolution
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.cache_table)
    :ok
  end

  # Private Functions

  defp do_resolve(state, connection_pid, query_id, query) do
    case query.qdlist do
      [question | _] ->
        # Check view-local cache first
        case check_cache(state, question.name, question.type) do
          {:ok, cached_response} ->
            # Notify connection process of cache hit
            send(connection_pid, {:zone_lookup, query_id, :hit})
            response = update_response_id(cached_response, query.header.id)
            apply_rpz_and_respond(state, connection_pid, query_id, query, response)

          :miss ->
            # Notify connection process of cache miss
            send(connection_pid, {:zone_lookup, query_id, :miss})
            # Find zone and resolve
            resolve_query(state, connection_pid, query_id, query, question)
        end

      [] ->
        {:error, :format_error}
    end
  end

  defp resolve_query(state, connection_pid, query_id, query, question) do
    zone_name = find_zone_for_name(state.zones, question.name)

    if zone_name do
      case resolve_in_zone(state, connection_pid, query_id, query, zone_name) do
        {:ok, _} = success ->
          success

        {:error, _} = error ->
          # Zone resolution failed - try fallback forwarders if configured
          try_fallback(state, connection_pid, query_id, query, error)
      end
    else
      # No matching zone - try recursion if enabled
      if state.recursion_enabled do
        perform_recursion(state, connection_pid, query_id, query)
      else
        # Try fallback forwarders before refusing
        try_fallback(state, connection_pid, query_id, query, {:error, :refused})
      end
    end
  end

  defp resolve_in_zone(state, connection_pid, query_id, query, zone_name) do
    # Try different zone types in order
    zone_types = [:auth, :forward, :stub]
    view_name = state.name

    result =
      Enum.find_value(zone_types, fn zone_type ->
        case ZoneController.find_zone(view_name, zone_type, zone_name) do
          {:ok, zone_pid} ->
            module = zone_module(zone_type)

            case module.resolve(zone_pid, query) do
              {:ok, response} = result ->
                # Notify connection process
                send(connection_pid, {:zone_response, query_id, response})
                # Cache the response
                cache_response(state, query, response)
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
          perform_recursion(state, connection_pid, query_id, query)
        else
          {:error, :refused}
        end

      {:ok, response} ->
        apply_rpz_and_respond(state, connection_pid, query_id, query, response)

      error ->
        error
    end
  end

  defp perform_recursion(state, connection_pid, query_id, query) do
    # Notify connection process of recursive step
    send(connection_pid, {:recursive_step, query_id, %{step: :forward}})
    view_name = state.name

    # Try to find forward zone "." in current view, then fall back to default view
    zone_pid =
      case ZoneController.find_zone(view_name, :forward, ".") do
        {:ok, pid} ->
          pid

        :error ->
          # Fall back to default view's forward zone
          case ZoneController.find_zone("default", :forward, ".") do
            {:ok, pid} -> pid
            :error -> nil
          end
      end

    case zone_pid do
      nil ->
        # No forwarding configured
        {:error, :servfail}

      pid ->
        case YellowDog.Dns.Zone.Forward.resolve(pid, query) do
          {:ok, response} ->
            send(connection_pid, {:zone_response, query_id, response})
            cache_response(state, query, response)
            apply_rpz_and_respond(state, connection_pid, query_id, query, response)

          error ->
            error
        end
    end
  end

  defp try_fallback(state, connection_pid, query_id, query, original_error) do
    if state.fallback_forwarders != [] do
      Telemetry.debug("Attempting fallback forwarding", %{
        view: state.name,
        forwarders: length(state.fallback_forwarders)
      })

      case forward_to_fallback(state, query) do
        {:ok, response} ->
          send(connection_pid, {:zone_response, query_id, response})
          cache_response(state, query, response)
          apply_rpz_and_respond(state, connection_pid, query_id, query, response)

        {:error, _} ->
          original_error
      end
    else
      original_error
    end
  end

  defp forward_to_fallback(state, query) do
    query_data = DNS.to_iodata(query)

    Enum.reduce_while(1..max(state.fallback_retries, 1), {:error, :timeout}, fn _attempt, _acc ->
      result =
        Enum.find_value(state.fallback_forwarders, fn {ip, port} ->
          case send_udp_query(ip, port, query_data, state.fallback_timeout) do
            {:ok, response_data} ->
              try do
                response = DNS.Message.from_iodata(response_data)
                {:ok, response}
              rescue
                _e in [ArgumentError, MatchError, FunctionClauseError] -> nil
              end

            _ ->
              nil
          end
        end)

      case result do
        {:ok, _} = success -> {:halt, success}
        nil -> {:cont, {:error, :timeout}}
      end
    end)
  end

  defp send_udp_query(ip, port, data, timeout) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, ip, port, data)

          case :gen_udp.recv(socket, 0, timeout) do
            {:ok, {_addr, _port, response}} -> {:ok, response}
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_rpz_and_respond(state, connection_pid, query_id, query, response) do
    # Apply RPZ policies if configured
    final_response =
      if Enum.empty?(state.rpz_zones) do
        response
      else
        apply_rpz_policies(state, query, response)
      end

    # Notify connection process of RPZ evaluation
    send(connection_pid, {:rpz_evaluation, query_id, :complete})

    {:ok, final_response}
  end

  defp apply_rpz_policies(state, query, response) do
    alias YellowDog.Dns.Zone.RPZ

    Enum.reduce_while(state.rpz_zones, response, fn rpz_zone_name, acc ->
      case ZoneController.find_zone(state.name, :rpz, rpz_zone_name) do
        {:ok, rpz_pid} ->
          case RPZ.evaluate(rpz_pid, query, acc) do
            {:ok, modified_response} -> {:halt, modified_response}
            {:drop, nil} -> {:halt, acc}
            {:passthru, _} -> {:cont, acc}
          end

        :error ->
          {:cont, acc}
      end
    end)
  end

  defp find_zone_for_name(zones, query_name) do
    normalized = normalize_name(query_name)

    # Handle both simple zone names and {type, name} tuples
    Enum.find_value(zones, fn
      {_type, zone_name} ->
        zone_suffix = normalize_name(zone_name)

        if String.ends_with?(normalized, zone_suffix) or normalized == zone_suffix do
          zone_name
        else
          nil
        end

      zone_name when is_binary(zone_name) ->
        zone_suffix = normalize_name(zone_name)

        if String.ends_with?(normalized, zone_suffix) or normalized == zone_suffix do
          zone_name
        else
          nil
        end
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
    case query.qdlist do
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
    all_records = response.anlist ++ response.nslist ++ response.arlist

    case all_records do
      [] -> 300
      records -> Enum.reduce(records, 300, fn r, acc -> min(r.ttl, acc) end) |> max(60)
    end
  end

  defp update_response_id(response, new_id) do
    %{response | header: %{response.header | id: new_id}}
  end

  defp normalize_name(%DNS.Message.Domain{} = domain) do
    domain
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp parse_acl(:any), do: :any
  defp parse_acl(:all), do: :any

  defp parse_acl(acl_name) when is_binary(acl_name) do
    {:named, acl_name}
  end

  defp parse_acl(%ACL{} = acl), do: acl

  defp parse_acl(rules) when is_list(rules) do
    ACL.new("inline", rules)
  end

  defp parse_acl(_), do: :any

  defp acl_matches?(:any, _client_ip), do: true

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
