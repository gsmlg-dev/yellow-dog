defmodule YellowDog.Netman.ReconciliationEngine do
  @moduledoc """
  Core desired-state reconciliation loop.

  Cycle: `observe() → diff(desired, observed) → apply(diffs)`

  Runs on a periodic timer (default 30s) plus event-triggered reconciliation
  with 100ms debounce.
  """

  @compile {:no_warn_undefined, [:telemetry, YellowDog.Resolved]}

  use GenServer

  require Logger

  alias YellowDog.Netman.{EventBus, PolicyEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Kernel.{LinkMonitor, AddressManager, RouteManager}
  alias YellowDog.Netman.Types.{Diff, DesiredState, ObservedState}

  @default_interval 30_000
  @debounce_ms 100
  @default_activation_timeout_ms 130_000
  @max_activation_timeout_ms 300_000
  @activation_poll_interval_ms 20
  @default_deactivation_timeout_ms 31_000
  @max_deactivation_timeout_ms 60_000
  @deactivation_poll_interval_ms 20

  defstruct [:timer_ref, :debounce_ref, :last_default_route, :interval, reconciling: false]

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate reconciliation."
  @spec reconcile() :: :ok
  def reconcile do
    GenServer.cast(__MODULE__, :reconcile)
  end

  @doc "Activate a specific profile."
  @spec activate(String.t()) :: :ok | {:error, term()}
  def activate(profile_id) do
    GenServer.call(__MODULE__, {:activate, profile_id})
  end

  @doc "Activate every interface selected by a profile and wait for terminal convergence."
  @spec activate_and_wait(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def activate_and_wait(profile_id, opts \\ []) do
    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Application.get_env(
          :yellow_dog_netman,
          :activation_timeout_ms,
          @default_activation_timeout_ms
        )
      end)

    if is_integer(timeout) and timeout > 0 and timeout <= @max_activation_timeout_ms do
      case GenServer.call(__MODULE__, {:activate_selected, profile_id}) do
        {:ok, connections} -> await_activation(profile_id, connections, timeout)
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_timeout}
    end
  end

  @doc "Activate one profile/interface connection and wait for terminal convergence."
  @spec activate_connection_and_wait(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def activate_connection_and_wait(profile_id, interface, opts \\ []) do
    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Application.get_env(
          :yellow_dog_netman,
          :activation_timeout_ms,
          @default_activation_timeout_ms
        )
      end)

    if is_integer(timeout) and timeout > 0 and timeout <= @max_activation_timeout_ms do
      case GenServer.call(__MODULE__, {:activate_connection, profile_id, interface}) do
        {:ok, connection} -> await_activation(profile_id, [connection], timeout)
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_timeout}
    end
  end

  @doc "Deactivate every connection using a profile."
  @spec deactivate(String.t()) :: :ok | {:error, term()}
  def deactivate(profile_id) do
    GenServer.call(__MODULE__, {:deactivate, profile_id})
  end

  @doc "Deactivate one profile/interface connection and wait for terminal cleanup."
  @spec deactivate_connection_and_wait(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deactivate_connection_and_wait(profile_id, interface, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_deactivation_timeout_ms)

    if is_integer(timeout) and timeout > 0 and timeout <= @max_deactivation_timeout_ms do
      case GenServer.call(__MODULE__, {:deactivate_connection, profile_id, interface}) do
        {:ok, :deactivated} ->
          {:ok, %{profile_id: profile_id, interface: interface, state: :deactivated}}

        {:ok, connection} ->
          await_deactivation(profile_id, connection, timeout)

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_timeout}
    end
  end

  @doc "Returns a bounded reconciliation health snapshot."
  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    GenServer.call(__MODULE__, :health)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    interval =
      Application.get_env(:yellow_dog_netman, :reconciliation_interval_ms, @default_interval)

    # Subscribe to relevant events
    EventBus.subscribe("netman:link:*")
    EventBus.subscribe("netman:profile:changed")
    EventBus.subscribe("netman:connection:*")

    # Schedule initial reconciliation
    Process.send_after(self(), :initial_reconcile, 100)

    # Schedule periodic reconciliation
    timer_ref = Process.send_after(self(), :periodic_reconcile, interval)

    {:ok, %__MODULE__{timer_ref: timer_ref, interval: interval}}
  end

  @impl true
  def handle_call({:activate, profile_id}, _from, state) do
    result =
      case ProfileStore.get(profile_id) do
        {:ok, profile} ->
          interface = profile.interface || find_matching_interface(profile)

          if interface do
            case Connection.Supervisor.find_connection(interface) do
              {:ok, pid} ->
                Connection.FSM.activate(pid)
                :ok

              :error ->
                case Connection.Supervisor.start_connection(interface, profile) do
                  {:ok, pid} ->
                    Connection.FSM.activate(pid)
                    :ok

                  {:error, _} = error ->
                    error
                end
            end
          else
            {:error, :no_matching_interface}
          end

        {:error, _} = error ->
          error
      end

    {:reply, result, state}
  end

  def handle_call({:activate_selected, profile_id}, _from, state) do
    result = activate_selected_profile(profile_id)
    {:reply, result, state}
  end

  def handle_call({:activate_connection, profile_id, interface}, _from, state) do
    result = activate_selected_connection(profile_id, interface)
    {:reply, result, state}
  end

  def handle_call({:deactivate, profile_id}, _from, state) do
    result =
      case connection_pids_for_profile(profile_id) do
        [] ->
          {:error, :not_found}

        pids ->
          Enum.each(pids, &Connection.FSM.deactivate/1)
          :ok
      end

    {:reply, result, state}
  end

  def handle_call({:deactivate_connection, profile_id, interface}, _from, state) do
    result = deactivate_selected_connection(profile_id, interface)
    {:reply, result, state}
  end

  def handle_call(:health, _from, state) do
    result =
      try do
        pending_changes =
          LinkMonitor.list_links()
          |> then(fn links -> diff(compute_desired(links), observe(links)) end)
          |> length()

        status = if state.reconciling or pending_changes > 0, do: :degraded, else: :healthy
        {:ok, %{status: status, pending_changes: pending_changes}}
      rescue
        _exception -> {:error, :reconciliation_failed}
      catch
        _kind, _reason -> {:error, :reconciliation_failed}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    state = schedule_debounced_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:initial_reconcile, state) do
    {:noreply, do_reconcile(state)}
  end

  def handle_info(:periodic_reconcile, %{reconciling: true} = state) do
    # Skip overlapping reconciliation; reschedule
    timer_ref = Process.send_after(self(), :periodic_reconcile, state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:periodic_reconcile, state) do
    state = %{state | reconciling: true}

    state =
      try do
        do_reconcile(state)
      rescue
        e ->
          Logger.error("Reconciliation crashed: #{Exception.message(e)}")
          state
      end

    timer_ref = Process.send_after(self(), :periodic_reconcile, state.interval)
    {:noreply, %{state | timer_ref: timer_ref, reconciling: false}}
  end

  def handle_info(:debounced_reconcile, %{reconciling: true} = state) do
    # Re-schedule instead of dropping — ensures events during reconciliation aren't lost
    ref = Process.send_after(self(), :debounced_reconcile, @debounce_ms)
    {:noreply, %{state | debounce_ref: ref}}
  end

  def handle_info(:debounced_reconcile, state) do
    state = %{state | reconciling: true}

    state =
      try do
        do_reconcile(state)
      rescue
        e ->
          Logger.error("Reconciliation crashed: #{Exception.message(e)}")
          state
      end

    {:noreply, %{state | debounce_ref: nil, reconciling: false}}
  end

  def handle_info({:netman_event, "netman:profile:changed", {event, profile_id}}, state)
      when event in [:updated, :reloaded] do
    # Push updated profile directly to running FSM (avoids stale cached profile)
    push_profile_to_fsm(profile_id)
    state = schedule_debounced_reconcile(state)
    {:noreply, state}
  end

  def handle_info({:netman_event, _topic, _message}, state) do
    state = schedule_debounced_reconcile(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    :ok
  end

  ## Reconciliation Logic

  defp do_reconcile(state) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:yellow_dog, :netman, :reconciliation, :start],
      %{count: 1},
      %{}
    )

    # Cache link list once per cycle — avoids repeated ETS reads in
    # observe(), compute_desired(), and find_matching_interface()
    links = LinkMonitor.list_links()

    observed = observe(links)
    desired = compute_desired(links)
    diffs = diff(desired, observed)

    {applied, failed} =
      Enum.reduce(diffs, {0, 0}, fn d, {ok, err} ->
        case apply_diff(d) do
          :ok ->
            {ok + 1, err}

          {:error, reason} ->
            Logger.warning(
              "Failed to apply diff #{d.action} on #{d.interface || "global"}: #{inspect(reason)}"
            )

            {ok, err + 1}
        end
      end)

    duration = System.monotonic_time(:millisecond) - start_time

    diffs_count = length(diffs)

    :telemetry.execute(
      [:yellow_dog, :netman, :reconciliation, :stop],
      %{
        duration_ms: duration,
        diffs_count: diffs_count,
        applied_count: applied,
        failed_count: failed
      },
      %{}
    )

    if diffs_count > 0 do
      Logger.info(
        "Reconciliation complete: #{diffs_count} diffs, #{applied} applied in #{duration}ms"
      )
    end

    check_default_route_change(state)
  end

  defp check_default_route_change(state) do
    connections = Connection.Supervisor.list_connections()
    new_default = PolicyEngine.default_route(connections)

    if new_default != state.last_default_route do
      old_id =
        case state.last_default_route do
          {:ok, id} -> id
          _ -> nil
        end

      new_id =
        case new_default do
          {:ok, id} -> id
          _ -> nil
        end

      :telemetry.execute(
        [:yellow_dog, :netman, :policy, :default_route_change],
        %{count: 1},
        %{old: old_id, new: new_id, reason: :reconciliation}
      )

      %{state | last_default_route: new_default}
    else
      state
    end
  end

  @doc false
  def observe(links \\ LinkMonitor.list_links()) do
    links_map = Enum.into(links, %{}, fn link -> {link.interface, link} end)

    addresses = AddressManager.list_all()
    routes = RouteManager.list_all()

    %ObservedState{links: links_map, addresses: addresses, routes: routes}
  end

  @doc false
  def compute_desired(links \\ LinkMonitor.list_links()) do
    profiles = ProfileStore.list()

    matched =
      for profile <- profiles,
          profile.autoconnect,
          link <- links,
          matches_profile?(profile, link) do
        {profile, link.interface}
      end

    DesiredState.from_profiles(matched)
  end

  @doc """
  Computes diffs between desired and observed state.

  Public for testing.
  """
  @spec diff(DesiredState.t(), ObservedState.t()) :: [Diff.t()]
  def diff(%DesiredState{} = desired, %ObservedState{} = observed) do
    activate_diffs = compute_activation_diffs(desired, observed)
    deactivate_diffs = compute_deactivation_diffs(desired, observed)
    address_diffs = compute_address_diffs(desired, observed)
    mtu_diffs = compute_mtu_diffs(desired, observed)
    route_diffs = compute_route_diffs(desired, observed)
    link_state_diffs = compute_link_state_diffs(desired, observed)

    activate_diffs ++
      deactivate_diffs ++
      address_diffs ++ mtu_diffs ++ route_diffs ++ link_state_diffs
  end

  defp compute_activation_diffs(desired, observed) do
    for {_id, conn} <- desired.connections,
        Map.has_key?(observed.links, conn.interface),
        not connection_active?(conn.interface) do
      Diff.new(:activate_connection, conn.interface, %{profile_id: conn.profile_id})
    end
  end

  defp compute_deactivation_diffs(desired, _observed) do
    # Stop FSMs whose profile no longer exists (deleted profiles).
    # Connections with existing profiles (even autoconnect=false) are left alone
    # since they may have been manually activated.
    # Disconnected/failed FSMs are also cleaned up for deleted profiles —
    # otherwise they block the interface from being used by new profiles.
    active_connections = Connection.Supervisor.list_connections()

    for conn <- active_connections,
        not Map.has_key?(desired.connections, {conn.profile_id, conn.interface}),
        ProfileStore.get(conn.profile_id) == {:error, :not_found} do
      Diff.new(:deactivate_connection, conn.interface)
    end
  end

  defp compute_address_diffs(desired, observed) do
    ipv4_diffs =
      for {_id, conn} <- desired.connections,
          connection_active?(conn.interface),
          conn.ipv4.method == :manual,
          conn.ipv4.address != nil,
          {addr, prefix_len} = parse_desired_cidr(conn.ipv4.address),
          not address_present?(observed.addresses, conn.interface, addr) do
        Diff.new(:add_address, conn.interface, %{address: addr, prefix_len: prefix_len})
      end

    ipv6_diffs =
      for {_id, conn} <- desired.connections,
          connection_active?(conn.interface),
          conn.ipv6.method == :manual,
          conn.ipv6[:address] != nil,
          {addr, prefix_len} = parse_desired_cidr(conn.ipv6.address),
          not address_present?(observed.addresses, conn.interface, addr) do
        Diff.new(:add_address, conn.interface, %{address: addr, prefix_len: prefix_len})
      end

    ipv4_diffs ++ ipv6_diffs
  end

  defp parse_desired_cidr(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix] ->
        max_prefix = default_prefix(addr)

        case Integer.parse(prefix) do
          {n, ""} when n >= 0 and n <= max_prefix -> {addr, n}
          _ -> {addr, max_prefix}
        end

      [addr] ->
        {addr, default_prefix(addr)}
    end
  end

  defp default_prefix(addr) do
    if String.contains?(addr, ":"), do: 128, else: 32
  end

  defp address_present?(addresses, interface, addr) do
    addresses
    |> Map.get(interface, [])
    |> Enum.any?(&(&1.address == addr))
  end

  defp compute_route_diffs(desired, observed) do
    ipv4_diffs =
      for {_id, conn} <- desired.connections,
          connection_active?(conn.interface),
          conn.ipv4.method == :manual,
          conn.ipv4[:gateway] != nil,
          not route_present?(observed.routes, "default", conn.ipv4.gateway, conn.interface) do
        metric =
          PolicyEngine.route_metrics([%{profile_id: conn.profile_id, priority: conn.priority}])

        conn_metric = Map.get(metric, conn.profile_id, 100)

        Diff.new(:add_route, conn.interface, %{
          destination: "default",
          gateway: conn.ipv4.gateway,
          interface: conn.interface,
          metric: conn_metric,
          table: 254,
          protocol: :static,
          scope: :global,
          family: :inet
        })
      end

    ipv6_diffs =
      for {_id, conn} <- desired.connections,
          connection_active?(conn.interface),
          conn.ipv6.method == :manual,
          conn.ipv6[:gateway] != nil,
          not route_present?(observed.routes, "default", conn.ipv6.gateway, conn.interface) do
        metric =
          PolicyEngine.route_metrics([%{profile_id: conn.profile_id, priority: conn.priority}])

        conn_metric = Map.get(metric, conn.profile_id, 100)

        Diff.new(:add_route, conn.interface, %{
          destination: "default",
          gateway: conn.ipv6.gateway,
          interface: conn.interface,
          metric: conn_metric,
          table: 254,
          protocol: :static,
          scope: :global,
          family: :inet6
        })
      end

    ipv4_diffs ++ ipv6_diffs
  end

  defp route_present?(routes, destination, gateway, interface) do
    Enum.any?(routes, fn r ->
      r.destination == destination and r.gateway == gateway and r.interface == interface
    end)
  end

  # DNS diffs are intentionally not computed by the reconciliation engine.
  # The FSM's push_dns/1 is the authoritative DNS source because it merges both
  # profile-configured DNS and DHCP-provided DNS servers. If we pushed profile-only
  # DNS here, we'd overwrite the DHCP servers that the FSM already applied.
  # DNS is pushed by the FSM on: activation, profile update, and lease renewal.

  defp compute_link_state_diffs(desired, observed) do
    for {_id, conn} <- desired.connections,
        connection_active?(conn.interface),
        link = Map.get(observed.links, conn.interface),
        link != nil,
        link.state == :down do
      Diff.new(:set_link_up, conn.interface)
    end
  end

  defp compute_mtu_diffs(desired, observed) do
    for {_id, conn} <- desired.connections,
        conn.mtu != nil,
        connection_active?(conn.interface),
        link = Map.get(observed.links, conn.interface),
        link != nil,
        link.mtu != conn.mtu do
      Diff.new(:set_mtu, conn.interface, %{mtu: conn.mtu})
    end
  end

  defp apply_diff(%Diff{action: :activate_connection, interface: iface, params: params}) do
    case ProfileStore.get(params.profile_id) do
      {:ok, profile} ->
        # If a failed FSM exists, re-activate it instead of starting a new one
        case Connection.Supervisor.find_connection(iface) do
          {:ok, pid} ->
            Connection.FSM.activate(pid)
            :ok

          :error ->
            case Connection.Supervisor.start_connection(iface, profile) do
              {:ok, _pid} -> :ok
              {:error, _} = error -> error
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_diff(%Diff{action: :deactivate_connection, interface: iface}) do
    Connection.Supervisor.stop_connection(iface)
  end

  defp apply_diff(%Diff{action: :update_profile, params: %{profile: profile, pid: pid}}) do
    Connection.FSM.update_profile(pid, profile)
    :ok
  end

  defp apply_diff(%Diff{action: :add_address, interface: iface, params: params}) do
    AddressManager.add_address(iface, params.address, params.prefix_len)
  end

  defp apply_diff(%Diff{action: :remove_address, interface: iface, params: params}) do
    AddressManager.remove_address(iface, params.address, params.prefix_len)
  end

  defp apply_diff(%Diff{action: :add_route, params: params}) do
    RouteManager.add_route(params)
  end

  defp apply_diff(%Diff{action: :remove_route, params: params}) do
    RouteManager.remove_route(params)
  end

  defp apply_diff(%Diff{action: :set_mtu, interface: iface, params: %{mtu: mtu}}) do
    LinkMonitor.set_mtu(iface, mtu)
  end

  defp apply_diff(%Diff{action: :set_link_up, interface: iface}) do
    LinkMonitor.set_link_up(iface)
  end

  defp apply_diff(%Diff{action: :set_link_down, interface: iface}) do
    LinkMonitor.set_link_down(iface)
  end

  defp apply_diff(%Diff{action: action}) do
    Logger.warning("Unhandled diff action: #{action}")
    {:error, {:unhandled_action, action}}
  end

  ## Helpers

  defp matches_profile?(profile, link) do
    profile.type == :ethernet and
      (profile.interface == nil or profile.interface == link.interface) and
      link.kind != "loopback"
  end

  defp connection_active?(interface) do
    case Connection.Supervisor.find_connection(interface) do
      {:ok, pid} ->
        case Connection.FSM.get_state(pid) do
          {:ok, %{state: :failed}} -> false
          {:ok, _} -> true
          {:error, _} -> false
        end

      :error ->
        false
    end
  end

  defp find_matching_interface(profile) do
    LinkMonitor.list_links()
    |> Enum.find(fn link -> matches_profile?(profile, link) end)
    |> case do
      nil -> nil
      link -> link.interface
    end
  end

  defp activate_selected_profile(profile_id) do
    with {:ok, profile} <- ProfileStore.get(profile_id),
         [_ | _] = interfaces <- selected_interfaces(profile),
         {:ok, connections} <- prepare_connections(profile, interfaces) do
      Enum.each(connections, fn %{pid: pid} -> Connection.FSM.activate(pid) end)
      {:ok, connections}
    else
      [] -> {:error, :no_matching_interface}
      {:error, _reason} = error -> error
    end
  end

  defp activate_selected_connection(profile_id, interface) do
    with {:ok, profile} <- ProfileStore.get(profile_id),
         {:ok, link} <- fetch_link(interface),
         true <- matches_profile?(profile, link),
         {:ok, pid} <- prepare_connection(profile, interface) do
      Connection.FSM.activate(pid)
      {:ok, %{interface: interface, pid: pid}}
    else
      false ->
        {:error, :no_matching_interface}

      {:error, reason} when reason in [:not_found, :no_matching_interface] ->
        {:error, reason}

      {:error, reason} ->
        {:error,
         {:activation_failed,
          %{
            profile_id: profile_id,
            interface: interface,
            state: :prepare,
            reason: reason
          }}}
    end
  end

  defp deactivate_selected_connection(profile_id, interface) do
    case Connection.Supervisor.find_connection(interface) do
      {:ok, pid} ->
        deactivate_running_connection(profile_id, interface, pid)

      :error ->
        with {:ok, profile} <- ProfileStore.get(profile_id),
             {:ok, link} <- fetch_link(interface),
             true <- matches_profile?(profile, link) do
          {:ok, :deactivated}
        else
          false -> {:error, :no_matching_interface}
          {:error, _reason} = error -> error
        end
    end
  end

  defp deactivate_running_connection(profile_id, interface, pid) do
    case Connection.FSM.get_state(pid) do
      {:ok, %{profile_id: ^profile_id, state: state}}
      when state in [:disconnected, :unavailable] ->
        {:ok, :deactivated}

      {:ok, %{profile_id: ^profile_id}} ->
        Connection.FSM.deactivate(pid)
        {:ok, %{interface: interface, pid: pid}}

      {:ok, _other_connection} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error,
         {:deactivation_failed,
          %{
            profile_id: profile_id,
            interface: interface,
            state: :not_running,
            reason: reason
          }}}
    end
  end

  defp fetch_link(interface) do
    case LinkMonitor.get_link(interface) do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  defp selected_interfaces(%{interface: interface}) when is_binary(interface), do: [interface]

  defp selected_interfaces(profile) do
    LinkMonitor.list_links()
    |> Enum.filter(&matches_profile?(profile, &1))
    |> Enum.map(& &1.interface)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp prepare_connections(profile, interfaces) do
    Enum.reduce_while(interfaces, {:ok, []}, fn interface, {:ok, connections} ->
      case prepare_connection(profile, interface) do
        {:ok, pid} ->
          {:cont, {:ok, [%{interface: interface, pid: pid} | connections]}}

        {:error, reason} ->
          {:halt,
           {:error,
            {:activation_failed,
             %{
               profile_id: profile.id,
               interface: interface,
               state: :prepare,
               reason: reason
             }}}}
      end
    end)
    |> case do
      {:ok, connections} -> {:ok, Enum.reverse(connections)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_connection(profile, interface) do
    case Connection.Supervisor.find_connection(interface) do
      {:ok, pid} ->
        case Connection.FSM.get_state(pid) do
          {:ok, %{profile_id: profile_id}} when profile_id != profile.id ->
            {:error, {:interface_in_use, profile_id}}

          {:ok, _connection} ->
            Connection.FSM.update_profile(pid, profile)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        Connection.Supervisor.start_connection(interface, profile)
    end
  end

  defp await_activation(profile_id, connections, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_activation(profile_id, connections, deadline, timeout)
  end

  defp await_activation(profile_id, connections, deadline, timeout) do
    observations = Enum.map(connections, &observe_connection/1)

    case Enum.find(observations, &terminal_activation_failure?/1) do
      nil ->
        pending = Enum.reject(observations, &(&1.state == :activated))

        if pending == [] do
          {:ok,
           Enum.map(observations, fn observation ->
             %{
               profile_id: profile_id,
               interface: observation.interface,
               state: :activated
             }
           end)}
        else
          await_pending_activation(profile_id, connections, pending, deadline, timeout)
        end

      failure ->
        {:error,
         {:activation_failed,
          %{
            profile_id: profile_id,
            interface: failure.interface,
            state: failure.state,
            reason: failure.reason
          }}}
    end
  end

  defp await_pending_activation(profile_id, connections, pending, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error,
       {:activation_timeout,
        %{
          profile_id: profile_id,
          pending: Enum.map(pending, &Map.take(&1, [:interface, :state])),
          timeout_ms: timeout
        }}}
    else
      Process.sleep(min(@activation_poll_interval_ms, remaining))
      await_activation(profile_id, connections, deadline, timeout)
    end
  end

  defp await_deactivation(profile_id, connection, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_deactivation(profile_id, connection, deadline, timeout)
  end

  defp await_deactivation(profile_id, connection, deadline, timeout) do
    observation = observe_connection(connection)

    cond do
      observation.state in [:disconnected, :unavailable] ->
        {:ok,
         %{
           profile_id: profile_id,
           interface: observation.interface,
           state: :deactivated
         }}

      observation.state == :not_running ->
        {:error,
         {:deactivation_failed,
          %{
            profile_id: profile_id,
            interface: observation.interface,
            state: observation.state,
            reason: observation.reason
          }}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error,
         {:deactivation_timeout,
          %{
            profile_id: profile_id,
            interface: observation.interface,
            state: observation.state,
            timeout_ms: timeout
          }}}

      true ->
        Process.sleep(@deactivation_poll_interval_ms)
        await_deactivation(profile_id, connection, deadline, timeout)
    end
  end

  defp observe_connection(%{interface: interface, pid: pid}) do
    case Connection.FSM.get_state(pid) do
      {:ok, %{state: state} = connection} ->
        %{interface: interface, state: state, reason: Map.get(connection, :error)}

      {:error, reason} ->
        %{interface: interface, state: :not_running, reason: reason}
    end
  end

  defp terminal_activation_failure?(%{state: state}) when state in [:failed, :unavailable],
    do: true

  defp terminal_activation_failure?(%{state: :not_running}), do: true
  defp terminal_activation_failure?(_observation), do: false

  defp push_profile_to_fsm(profile_id) do
    case ProfileStore.get(profile_id) do
      {:ok, profile} ->
        profile_id
        |> connection_pids_for_profile()
        |> Enum.each(&Connection.FSM.update_profile(&1, profile))

      {:error, _reason} ->
        :ok
    end
  end

  defp connection_pids_for_profile(profile_id) do
    Connection.Supervisor.list_connections()
    |> Enum.flat_map(fn
      %{profile_id: ^profile_id, interface: interface} ->
        case Connection.Supervisor.find_connection(interface) do
          {:ok, pid} -> [pid]
          :error -> []
        end

      _connection ->
        []
    end)
  end

  defp schedule_debounced_reconcile(state) do
    if state.debounce_ref do
      state
    else
      ref = Process.send_after(self(), :debounced_reconcile, @debounce_ms)
      %{state | debounce_ref: ref}
    end
  end
end
