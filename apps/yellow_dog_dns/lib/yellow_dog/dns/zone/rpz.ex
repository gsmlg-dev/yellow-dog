defmodule YellowDog.Dns.Zone.RPZ do
  @moduledoc """
  Response Policy Zone (RPZ) for DNS firewall functionality.

  RPZ zones provide post-resolution response modification, allowing:
  - Domain blocking (NXDOMAIN, NODATA)
  - Redirection to walled gardens (Local-Data)
  - Whitelisting (PASSTHRU)
  - Silent drops (DROP)
  - TCP-only enforcement

  ## Policy Triggers

  - **QNAME** - Query name (domain being queried)
  - **CLIENT-IP** - DNS client IP address
  - **IP** - IP addresses in response (A/AAAA records)
  - **NSDNAME** - Authoritative nameserver name found during resolution
  - **NSIP** - Authoritative nameserver IP address

  ## Policy Actions

  - **NXDOMAIN** - Return "domain does not exist"
  - **NODATA** - Return "name exists but no data"
  - **PASSTHRU** - Allow (whitelist/exception)
  - **DROP** - Silently drop (client timeout)
  - **TCP-Only** - Force TCP retry
  - **Local-Data** - Return custom data (e.g., CNAME to walled garden)

  ## RPZ Matching

  - Multiple RPZs per view, ordered by specificity
  - More specific match wins (www.google.com matches google.com RPZ before com RPZ)
  - First matching trigger-action pair is applied

  ## Zone Data Format

  RPZ uses special owner names to encode triggers:
  - `example.com` - Matches QNAME example.com
  - `*.example.com` - Matches QNAME *.example.com
  - `32.1.168.192.rpz-client-ip` - Matches client IP 192.168.1.0/32
  - `32.1.168.192.rpz-ip` - Matches response IP 192.168.1.0/32
  - `ns.example.com.rpz-nsdname` - Matches nameserver name
  """

  use GenServer

  alias YellowDog.Telemetry
  alias YellowDog.Dns.Zone.Behaviour
  alias DNS.Message
  alias DNS.Message.RCode

  @behaviour Behaviour

  # Policy actions
  @action_nxdomain :nxdomain
  @action_nodata :nodata
  @action_passthru :passthru
  @action_drop :drop
  @action_tcp_only :tcp_only
  @action_local_data :local_data

  defstruct [
    :name,
    :view_name,
    :ets_table,
    :policy_order,
    policies: [],
    hit_count: 0,
    miss_count: 0
  ]

  # Client API

  @doc """
  Starts an RPZ zone process.

  ## Options

  - `:name` - Zone name (required)
  - `:view_name` - Parent view name for ETS table naming
  - `:policies` - List of RPZ policies
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    GenServer.start_link(__MODULE__, opts, name: Behaviour.zone_via_tuple(view_name, :rpz, zone_name))
  end

  @doc """
  Evaluates an RPZ policy against a query and response.

  Returns the modified response or the original if no policy matches.
  """
  @spec evaluate(pid(), Message.t(), Message.t()) ::
          {:ok, Message.t()} | {:passthru, Message.t()} | {:drop, nil}
  def evaluate(pid, query, response) do
    GenServer.call(pid, {:evaluate, query, response})
  end

  @doc """
  Checks if a query name matches any RPZ policy.

  Used for pre-resolution blocking (QNAME triggers).
  """
  @spec check_qname(pid(), String.t()) :: {:ok, map()} | :no_match
  def check_qname(pid, qname) do
    GenServer.call(pid, {:check_qname, qname})
  end

  @impl Behaviour
  def get_name(pid), do: GenServer.call(pid, :get_name)

  @doc """
  Gets the view name this zone belongs to.
  """
  @spec get_view(pid()) :: String.t()
  def get_view(pid), do: GenServer.call(pid, :get_view)

  @impl Behaviour
  def reload(pid, config), do: GenServer.call(pid, {:reload, config})

  @impl Behaviour
  def stats(pid), do: GenServer.call(pid, :stats)

  # For compatibility with zone interface, but RPZ doesn't resolve queries
  @impl Behaviour
  def resolve(_pid, _query), do: {:error, :not_supported}

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    policies = Keyword.get(opts, :policies, [])

    # Create view-specific ETS table
    table_name = :"rpz_#{view_name}_#{zone_name}"

    ets_table =
      :ets.new(table_name, [
        :set,
        :protected,
        read_concurrency: true
      ])

    # Load policies into ETS
    load_policies(ets_table, policies)

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
      ets_table: ets_table,
      policies: policies,
      policy_order: build_policy_order(policies)
    }

    Telemetry.info("RPZ zone started", %{
      name: zone_name,
      view: view_name,
      policy_count: length(policies)
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call(:get_view, _from, state) do
    {:reply, state.view_name, state}
  end

  @impl true
  def handle_call({:evaluate, query, response}, _from, state) do
    case evaluate_policies(state, query, response) do
      {:match, action, policy} ->
        state = %{state | hit_count: state.hit_count + 1}
        result = apply_action(action, policy, query, response)
        {:reply, result, state}

      :no_match ->
        state = %{state | miss_count: state.miss_count + 1}
        {:reply, {:passthru, response}, state}
    end
  end

  @impl true
  def handle_call({:check_qname, qname}, _from, state) do
    case lookup_qname_policy(state, qname) do
      {:ok, policy} ->
        state = %{state | hit_count: state.hit_count + 1}
        {:reply, {:ok, policy}, state}

      :no_match ->
        state = %{state | miss_count: state.miss_count + 1}
        {:reply, :no_match, state}
    end
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    policies = Keyword.get(config, :policies, state.policies)

    # Clear and reload ETS
    :ets.delete_all_objects(state.ets_table)
    load_policies(state.ets_table, policies)

    new_state = %{
      state
      | policies: policies,
        policy_order: build_policy_order(policies)
    }

    Telemetry.info("RPZ zone reloaded", %{
      name: state.name,
      policy_count: length(policies)
    })

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      view: state.view_name,
      policy_count: length(state.policies),
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      table_size: :ets.info(state.ets_table, :size)
    }

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.ets_table)
    :ok
  end

  # Private Functions

  defp load_policies(ets_table, policies) do
    Enum.each(policies, fn policy ->
      trigger = Map.get(policy, :trigger)
      pattern = Map.get(policy, :pattern)
      action = Map.get(policy, :action)

      key = {trigger, normalize_pattern(pattern)}
      :ets.insert(ets_table, {key, policy, action})
    end)
  end

  defp build_policy_order(policies) do
    # Sort by specificity (more specific patterns first)
    policies
    |> Enum.with_index()
    |> Enum.sort_by(fn {policy, _idx} ->
      pattern = Map.get(policy, :pattern, "")
      # More labels = more specific = earlier in order
      pattern |> String.split(".") |> length()
    end, :desc)
    |> Enum.map(fn {policy, _idx} -> policy end)
  end

  defp evaluate_policies(state, query, response) do
    qname = get_qname(query)

    with :no_match <- lookup_qname_policy(state, qname),
         :no_match <- check_response_ips(state, response) do
      :no_match
    else
      {:ok, policy} -> {:match, Map.get(policy, :action), policy}
    end
  end

  defp lookup_qname_policy(state, qname) do
    normalized = normalize_pattern(qname)

    # Try exact match first, then wildcards
    case :ets.lookup(state.ets_table, {:qname, normalized}) do
      [{_key, policy, _action}] ->
        {:ok, policy}

      [] ->
        # Try wildcard matches
        find_wildcard_match(state, :qname, normalized)
    end
  end

  defp find_wildcard_match(state, trigger, name) do
    labels = String.split(name, ".")

    # Try progressively less specific wildcards
    result =
      Enum.find_value(1..length(labels), fn n ->
        wildcard =
          ["*" | Enum.drop(labels, n)]
          |> Enum.join(".")

        case :ets.lookup(state.ets_table, {trigger, wildcard}) do
          [{_key, policy, _action}] -> {:ok, policy}
          [] -> nil
        end
      end)

    result || :no_match
  end

  defp check_response_ips(state, response) do
    # Extract A/AAAA records from response
    ips = for(rr <- response.anlist, rr.type in [:a, :aaaa], do: rr.rdata)

    # Check each IP against policies
    Enum.find_value(ips, :no_match, fn ip ->
      case lookup_ip_policy(state, ip) do
        {:ok, policy} -> {:ok, policy}
        :no_match -> nil
      end
    end)
  end

  defp lookup_ip_policy(state, ip) do
    # Convert IP to RPZ format and lookup
    rpz_name = ip_to_rpz(ip)

    case :ets.lookup(state.ets_table, {:ip, rpz_name}) do
      [{_key, policy, _action}] -> {:ok, policy}
      [] -> :no_match
    end
  end

  defp apply_action(@action_nxdomain, _policy, query, _response) do
    response = create_nxdomain_response(query)
    {:ok, response}
  end

  defp apply_action(@action_nodata, _policy, query, _response) do
    response = create_nodata_response(query)
    {:ok, response}
  end

  defp apply_action(@action_passthru, _policy, _query, response) do
    {:passthru, response}
  end

  defp apply_action(@action_drop, _policy, _query, _response) do
    {:drop, nil}
  end

  defp apply_action(@action_tcp_only, _policy, query, _response) do
    response = create_tc_response(query)
    {:ok, response}
  end

  defp apply_action(@action_local_data, policy, query, _response) do
    local_data = Map.get(policy, :local_data, [])
    response = create_local_data_response(query, local_data)
    {:ok, response}
  end

  defp apply_action(_unknown, _policy, _query, response) do
    {:passthru, response}
  end

  defp create_nxdomain_response(query),
    do: build_rpz_response(query, rcode: RCode.nx_domain())

  defp create_nodata_response(query),
    do: build_rpz_response(query, rcode: RCode.no_error())

  defp create_tc_response(query),
    do: build_rpz_response(query, tc: 1, rcode: RCode.no_error())

  defp create_local_data_response(query, local_data),
    do: build_rpz_response(query, aa: 1, rcode: RCode.no_error(), anlist: local_data)

  defp build_rpz_response(query, opts) do
    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: Keyword.get(opts, :aa, 0),
          tc: Keyword.get(opts, :tc, 0),
          ra: 1,
          rcode: Keyword.fetch!(opts, :rcode)
      },
      qdlist: query.qdlist,
      anlist: Keyword.get(opts, :anlist, []),
      nslist: [],
      arlist: []
    }
  end

  defp get_qname(query) do
    case query.qdlist do
      [question | _] -> to_string(question.name)
      [] -> ""
    end
  end

  defp normalize_pattern(pattern) do
    pattern
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp ip_to_rpz({a, b, c, d}) do
    "#{d}.#{c}.#{b}.#{a}"
  end

  defp ip_to_rpz({a, b, c, d, e, f, g, h}) do
    # IPv6 in nibble format
    parts =
      [a, b, c, d, e, f, g, h]
      |> Enum.flat_map(fn word ->
        [
          rem(div(word, 4096), 16),
          rem(div(word, 256), 16),
          rem(div(word, 16), 16),
          rem(word, 16)
        ]
      end)
      |> Enum.reverse()
      |> Enum.map(&Integer.to_string(&1, 16))

    Enum.join(parts, ".")
  end

end
