defmodule YellowDog.Netman.ReconciliationEngine do
  @moduledoc """
  Core desired-state reconciliation loop.

  Cycle: `observe() → diff(desired, observed) → plan(diffs) → apply(plan) → verify()`

  Runs on a periodic timer (default 30s) plus event-triggered reconciliation
  with 100ms debounce.
  """

  use GenServer

  require Logger

  alias YellowDog.Netman.{EventBus, PolicyEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Kernel.{LinkMonitor, AddressManager, Netlink, RouteManager}
  alias YellowDog.Netman.Types.{Diff, DesiredState, ObservedState}

  @default_interval 30_000
  @debounce_ms 100

  defstruct [:timer_ref, :debounce_ref, :last_default_route, reconciling: false]

  ## Client API

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

  @doc "Deactivate a specific connection."
  @spec deactivate(String.t()) :: :ok | {:error, term()}
  def deactivate(profile_id) do
    GenServer.call(__MODULE__, {:deactivate, profile_id})
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    interval =
      Application.get_env(:yellow_dog_netman, :reconciliation_interval_ms, @default_interval)

    # Subscribe to relevant events
    EventBus.subscribe("netman:link:*")
    EventBus.subscribe("netman:profile:changed")

    # Schedule initial reconciliation
    Process.send_after(self(), :initial_reconcile, 100)

    # Schedule periodic reconciliation
    timer_ref = Process.send_after(self(), :periodic_reconcile, interval)

    {:ok, %__MODULE__{timer_ref: timer_ref}}
  end

  @impl true
  def handle_call({:activate, profile_id}, _from, state) do
    result =
      case ProfileStore.get(profile_id) do
        {:ok, profile} ->
          interface = profile.interface || find_matching_interface(profile)

          if interface do
            Connection.Supervisor.start_connection(interface, profile)
            :ok
          else
            {:error, :no_matching_interface}
          end

        {:error, _} = error ->
          error
      end

    {:reply, result, state}
  end

  def handle_call({:deactivate, profile_id}, _from, state) do
    result =
      case Connection.Supervisor.find_connection_by_profile(profile_id) do
        {:ok, pid} ->
          Connection.FSM.deactivate(pid)
          :ok

        :error ->
          {:error, :not_found}
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
    interval =
      Application.get_env(:yellow_dog_netman, :reconciliation_interval_ms, @default_interval)

    timer_ref = Process.send_after(self(), :periodic_reconcile, interval)
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

    interval =
      Application.get_env(:yellow_dog_netman, :reconciliation_interval_ms, @default_interval)

    timer_ref = Process.send_after(self(), :periodic_reconcile, interval)
    {:noreply, %{state | timer_ref: timer_ref, reconciling: false}}
  end

  def handle_info(:debounced_reconcile, %{reconciling: true} = state) do
    # Skip overlapping reconciliation
    {:noreply, %{state | debounce_ref: nil}}
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

    observed = observe()
    desired = compute_desired()
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

    :telemetry.execute(
      [:yellow_dog, :netman, :reconciliation, :stop],
      %{
        duration_ms: duration,
        diffs_count: length(diffs),
        applied_count: applied,
        failed_count: failed
      },
      %{}
    )

    if length(diffs) > 0 do
      Logger.info(
        "Reconciliation complete: #{length(diffs)} diffs, #{applied} applied in #{duration}ms"
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
  def observe do
    links =
      LinkMonitor.list_links()
      |> Enum.into(%{}, fn link -> {link.interface, link} end)

    addresses = AddressManager.list_all()
    routes = RouteManager.list_all()

    %ObservedState{links: links, addresses: addresses, routes: routes}
  end

  @doc false
  def compute_desired do
    profiles = ProfileStore.list()
    links = LinkMonitor.list_links()

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
    activate_diffs ++ deactivate_diffs
  end

  defp compute_activation_diffs(desired, observed) do
    for {_id, conn} <- desired.connections,
        Map.has_key?(observed.links, conn.interface),
        not connection_active?(conn.interface) do
      Diff.new(:activate_connection, conn.interface, %{profile_id: conn.profile_id})
    end
  end

  defp compute_deactivation_diffs(_desired, _observed) do
    # In Phase 1, we don't auto-deactivate — only explicit user action
    []
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

  defp apply_diff(%Diff{action: :update_dns, interface: iface, params: params}) do
    if Code.ensure_loaded?(YellowDog.Resolved) do
      apply(YellowDog.Resolved, :set_link_dns, [iface, params])
    else
      :ok
    end
  end

  defp apply_diff(%Diff{action: :set_mtu, interface: iface, params: %{mtu: mtu}}) do
    Netlink.command(%{"cmd" => "link_set", "interface" => iface, "mtu" => mtu})
  end

  defp apply_diff(%Diff{action: :set_link_up, interface: iface}) do
    Netlink.command(%{"cmd" => "link_set", "interface" => iface, "state" => "up"})
  end

  defp apply_diff(%Diff{action: :set_link_down, interface: iface}) do
    Netlink.command(%{"cmd" => "link_set", "interface" => iface, "state" => "down"})
  end

  defp apply_diff(%Diff{action: action}) do
    Logger.warning("Unhandled diff action: #{action}")
    :ok
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

  defp schedule_debounced_reconcile(state) do
    if state.debounce_ref do
      state
    else
      ref = Process.send_after(self(), :debounced_reconcile, @debounce_ms)
      %{state | debounce_ref: ref}
    end
  end
end
