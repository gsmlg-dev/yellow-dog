defmodule YellowDog.Netman.Connection.FSM do
  @moduledoc """
  Per-interface connection state machine using `:gen_statem`.

  ## States (Phase 1)

      :unavailable → :disconnected → :prepare → :configuring →
      :ip_check → :activated → :deactivating → :failed

  ## Process Registration

  Registered via `{:via, Registry, {YellowDog.Netman.Registry, {:connection, interface}}}`.
  """

  @behaviour :gen_statem

  require Logger

  alias YellowDog.Netman.EventBus
  alias YellowDog.Netman.Kernel.{AddressManager, LinkMonitor, RouteManager}

  @type state ::
          :unavailable
          | :disconnected
          | :prepare
          | :configuring
          | :ip_check
          | :activated
          | :deactivating
          | :failed

  defstruct [
    :interface,
    :profile,
    :lease,
    current_state: :unavailable,
    error: nil
  ]

  ## Client API

  def start_link(opts) do
    interface = Keyword.fetch!(opts, :interface)
    profile = Keyword.fetch!(opts, :profile)

    :gen_statem.start_link(
      {:via, Registry, {YellowDog.Netman.Registry, {:connection, interface}}},
      __MODULE__,
      %{interface: interface, profile: profile},
      []
    )
  end

  def child_spec(opts) do
    interface = Keyword.fetch!(opts, :interface)

    %{
      id: {__MODULE__, interface},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Get current state of a connection FSM."
  @spec get_state(pid()) :: {:ok, map()} | {:error, term()}
  def get_state(pid) do
    :gen_statem.call(pid, :get_state)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Trigger activation."
  @spec activate(pid()) :: :ok
  def activate(pid) do
    :gen_statem.cast(pid, :activate)
  end

  @doc "Trigger deactivation."
  @spec deactivate(pid()) :: :ok
  def deactivate(pid) do
    :gen_statem.cast(pid, :deactivate)
  end

  ## gen_statem callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(%{interface: interface, profile: profile}) do
    data = %__MODULE__{
      interface: interface,
      profile: profile
    }

    EventBus.subscribe("netman:link:#{interface}")
    EventBus.subscribe("netman:address:#{interface}")

    # Check if interface already exists
    case LinkMonitor.get_link(interface) do
      nil ->
        emit_state_change(data, nil, :unavailable)
        {:ok, :unavailable, data}

      %{carrier: true} ->
        emit_state_change(data, nil, :disconnected)
        {:ok, :disconnected, data, [{:next_event, :internal, :auto_activate}]}

      _link ->
        emit_state_change(data, nil, :disconnected)
        {:ok, :disconnected, data}
    end
  end

  ## State: unavailable

  def unavailable(:info, {:netman_event, _, {:link_update, %{carrier: true}}}, data) do
    transition(data, :unavailable, :disconnected, [{:next_event, :internal, :auto_activate}])
  end

  def unavailable(:info, {:netman_event, _, {:link_update, _}}, data) do
    transition(data, :unavailable, :disconnected)
  end

  def unavailable({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :unavailable)}}]}
  end

  def unavailable(_event_type, _event, data), do: {:keep_state, data}

  ## State: disconnected

  def disconnected(:internal, :auto_activate, data) do
    if data.profile.autoconnect do
      transition(data, :disconnected, :prepare, [{:next_event, :internal, :setup_link}])
    else
      {:keep_state, data}
    end
  end

  def disconnected(:cast, :activate, data) do
    transition(data, :disconnected, :prepare, [{:next_event, :internal, :setup_link}])
  end

  def disconnected(:info, {:netman_event, _, {:link_update, %{carrier: true}}}, data) do
    {:keep_state, data, [{:next_event, :internal, :auto_activate}]}
  end

  def disconnected(:info, {:netman_event, _, {:removed, _}}, data) do
    transition(data, :disconnected, :unavailable)
  end

  def disconnected({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :disconnected)}}]}
  end

  def disconnected(_event_type, _event, data), do: {:keep_state, data}

  ## State: prepare

  def prepare(:internal, :setup_link, data) do
    # Set MTU if configured
    if mtu = data.profile.ethernet.mtu do
      YellowDog.Netman.Kernel.Netlink.command(%{
        "cmd" => "link_set",
        "interface" => data.interface,
        "mtu" => mtu
      })
    end

    # Bring link up
    YellowDog.Netman.Kernel.Netlink.command(%{
      "cmd" => "link_set",
      "interface" => data.interface,
      "state" => "up"
    })

    transition(data, :prepare, :configuring, [{:next_event, :internal, :configure_ip}])
  end

  def prepare({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :prepare)}}]}
  end

  def prepare(_event_type, _event, data), do: {:keep_state, data}

  ## State: configuring

  def configuring(:internal, :configure_ip, data) do
    case data.profile.ipv4.method do
      :auto ->
        start_dhcp(data)
        {:keep_state, data}

      :manual ->
        apply_static_ip(data)

      :disabled ->
        transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
    end
  end

  def configuring(:info, {:netman_event, _, {:add, %{scope: :global}}}, data) do
    # Got a global address — proceed to IP check
    transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
  end

  def configuring(:info, {:dhcp_lease_acquired, lease}, data) do
    data = %{data | lease: lease}
    transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
  end

  def configuring(:info, {:dhcp_lease_failed, _reason}, data) do
    transition(%{data | error: :dhcp_failed}, :configuring, :failed)
  end

  def configuring(:cast, :deactivate, data) do
    transition(data, :configuring, :deactivating, [{:next_event, :internal, :cleanup}])
  end

  def configuring({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :configuring)}}]}
  end

  def configuring(_event_type, _event, data), do: {:keep_state, data}

  ## State: ip_check

  def ip_check(:internal, :check_ip, data) do
    # Phase 1: basic check — just verify we have an address
    addresses = AddressManager.get_addresses(data.interface)
    has_global = Enum.any?(addresses, &(&1.scope == :global))

    if has_global or data.profile.ipv4.method == :disabled do
      transition(data, :ip_check, :activated, [{:next_event, :internal, :post_activate}])
    else
      # Retry after a short delay
      {:keep_state, data, [{:state_timeout, 2000, :retry_check}]}
    end
  end

  def ip_check(:state_timeout, :retry_check, data) do
    {:keep_state, data, [{:next_event, :internal, :check_ip}]}
  end

  def ip_check({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :ip_check)}}]}
  end

  def ip_check(_event_type, _event, data), do: {:keep_state, data}

  ## State: activated

  def activated(:internal, :post_activate, data) do
    install_routes(data)
    push_dns(data)
    EventBus.publish("netman:connection:#{data.profile.id}", {:activated, data.interface})
    {:keep_state, data}
  end

  def activated(:info, {:netman_event, _, {:link_update, %{carrier: false}}}, data) do
    # Carrier lost
    transition(data, :activated, :deactivating, [{:next_event, :internal, :cleanup}])
  end

  def activated(:cast, :deactivate, data) do
    transition(data, :activated, :deactivating, [{:next_event, :internal, :cleanup}])
  end

  def activated({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :activated)}}]}
  end

  def activated(_event_type, _event, data), do: {:keep_state, data}

  ## State: deactivating

  def deactivating(:internal, :cleanup, data) do
    release_dhcp(data)
    AddressManager.flush(data.interface)
    RouteManager.flush(data.interface)
    EventBus.publish("netman:connection:#{data.profile.id}", {:deactivated, data.interface})
    data = %{data | lease: nil}
    transition(data, :deactivating, :disconnected)
  end

  def deactivating({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :deactivating)}}]}
  end

  def deactivating(_event_type, _event, data), do: {:keep_state, data}

  ## State: failed

  def failed(:cast, :activate, data) do
    transition(%{data | error: nil}, :failed, :disconnected, [
      {:next_event, :internal, :auto_activate}
    ])
  end

  def failed(:info, {:netman_event, _, {:link_update, %{carrier: true}}}, data) do
    transition(%{data | error: nil}, :failed, :disconnected, [
      {:next_event, :internal, :auto_activate}
    ])
  end

  def failed({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :failed)}}]}
  end

  def failed(_event_type, _event, data), do: {:keep_state, data}

  ## Internal helpers

  defp transition(data, from, to, actions \\ []) do
    emit_state_change(data, from, to)
    data = %{data | current_state: to}
    {:next_state, to, data, actions}
  end

  defp emit_state_change(data, from, to) do
    :telemetry.execute(
      [:yellow_dog, :netman, :connection, :state_change],
      %{count: 1},
      %{
        interface: data.interface,
        from: from,
        to: to,
        profile_id: data.profile.id
      }
    )

    EventBus.publish("netman:connection:#{data.profile.id}", {:state_change, from, to})
  end

  defp start_dhcp(data) do
    # Integration with yellow_dog_dhcp_client
    case apply_dhcp_start(data.interface) do
      {:ok, _pid} ->
        Logger.info("DHCP started for #{data.interface}")

      {:error, reason} ->
        Logger.warning("DHCP start failed for #{data.interface}: #{inspect(reason)}")
        send(self(), {:dhcp_lease_failed, reason})
    end
  end

  defp apply_dhcp_start(interface) do
    if Code.ensure_loaded?(YellowDog.DhcpClient) do
      YellowDog.DhcpClient.start_interface(interface, mode: :hook)
    else
      {:error, :dhcp_client_not_available}
    end
  end

  defp apply_static_ip(data) do
    case data.profile.ipv4 do
      %{address: addr} when is_binary(addr) ->
        {ip, prefix} = parse_cidr(addr)
        AddressManager.add_address(data.interface, ip, prefix)
        transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])

      _ ->
        transition(%{data | error: :no_address_configured}, :configuring, :failed)
    end
  end

  defp release_dhcp(data) do
    if data.lease != nil and Code.ensure_loaded?(YellowDog.DhcpClient) do
      YellowDog.DhcpClient.release(data.interface)
    end
  end

  defp install_routes(data) do
    case data.profile.ipv4 do
      %{gateway: gw} when is_binary(gw) ->
        metrics = YellowDog.Netman.PolicyEngine.route_metrics([state_info(data, :activated)])
        metric = Map.get(metrics, data.profile.id, 100)

        RouteManager.add_route(%{
          destination: "default",
          gateway: gw,
          interface: data.interface,
          metric: metric
        })

      _ ->
        :ok
    end
  end

  defp push_dns(_data) do
    # Stub for resolved integration — yellow_dog_resolved doesn't exist yet
    :ok
  end

  defp state_info(data, state) do
    %{
      interface: data.interface,
      state: state,
      profile_id: data.profile.id,
      type: data.profile.type,
      autoconnect_priority: data.profile.autoconnect_priority,
      priority: data.profile.autoconnect_priority,
      lease: data.lease,
      error: data.error,
      dns: data.profile.ipv4.dns ++ data.profile.ipv6.dns
    }
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix] ->
        case Integer.parse(prefix) do
          {n, ""} -> {addr, n}
          _ -> {addr, 24}
        end

      [addr] ->
        {addr, 24}
    end
  end
end
