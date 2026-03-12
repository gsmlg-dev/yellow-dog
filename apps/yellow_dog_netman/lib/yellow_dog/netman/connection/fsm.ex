defmodule YellowDog.Netman.Connection.FSM do
  @moduledoc """
  Per-interface connection state machine using `:gen_statem`.

  ## States (Phase 1)

      :unavailable → :disconnected → :prepare → :configuring →
      :ip_check → :activated → :deactivating → :failed

  ## Process Registration

  Registered via `{:via, Registry, {YellowDog.Netman.Registry, {:connection, interface}}}`.
  """

  @compile {:no_warn_undefined, [:telemetry, YellowDog.DhcpClient]}

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

  @max_ip_check_retries 30
  @configuring_timeout_ms 120_000
  @prepare_timeout_ms 10_000
  @deactivating_timeout_ms 30_000
  @max_dhcp_retries 3
  @dhcp_base_retry_ms 2_000

  defstruct [
    :interface,
    :profile,
    :lease,
    current_state: :unavailable,
    error: nil,
    ip_check_retries: 0,
    dhcp_retries: 0
  ]

  ## Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
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

  @spec child_spec(keyword()) :: Supervisor.child_spec()
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

  @doc "Update the cached profile. Triggers reconfiguration if IP method changed."
  @spec update_profile(pid(), YellowDog.Netman.Types.Profile.t()) :: :ok
  def update_profile(pid, new_profile) do
    :gen_statem.cast(pid, {:update_profile, new_profile})
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
      transition(data, :disconnected, :prepare, [
        {:next_event, :internal, :setup_link},
        {:state_timeout, @prepare_timeout_ms, :setup_timeout}
      ])
    else
      {:keep_state, data}
    end
  end

  def disconnected(:cast, {:update_profile, new_profile}, data) do
    {:keep_state, %{data | profile: new_profile}}
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
    case setup_link(data) do
      :ok ->
        transition(data, :prepare, :configuring, [
          {:next_event, :internal, :configure_ip},
          {:state_timeout, @configuring_timeout_ms, :configuring_timeout}
        ])

      {:error, reason} ->
        Logger.warning("Link setup failed for #{data.interface}: #{inspect(reason)}")
        transition(%{data | error: {:setup_link_failed, reason}}, :prepare, :failed)
    end
  end

  def prepare(:state_timeout, :setup_timeout, data) do
    Logger.warning("Prepare timed out for #{data.interface}")
    transition(%{data | error: :setup_timeout}, :prepare, :failed)
  end

  def prepare(:info, {:netman_event, _, {:link_update, %{carrier: false}}}, data) do
    Logger.warning("Carrier lost during prepare for #{data.interface}")

    transition(data, :prepare, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def prepare(:info, {:netman_event, _, {:removed, _}}, data) do
    transition(data, :prepare, :unavailable)
  end

  def prepare(:cast, :deactivate, data) do
    transition(data, :prepare, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def prepare({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :prepare)}}]}
  end

  def prepare(_event_type, _event, data), do: {:keep_state, data}

  ## State: configuring

  def configuring(:internal, :configure_ip, data) do
    # Apply IPv6 static address if configured (independent of IPv4 method)
    apply_static_ipv6(data)

    case data.profile.ipv4.method do
      :auto ->
        start_dhcp(data)
        {:keep_state, data}

      :manual ->
        apply_static_ip(data)

      :disabled ->
        # IPv4 disabled — check if IPv6 needs time for SLAAC
        case data.profile.ipv6.method do
          :auto ->
            # Wait for kernel SLAAC to provide a global address via netlink
            {:keep_state, data}

          _ ->
            # :manual (already applied above), :disabled, :link_local — proceed
            transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
        end
    end
  end

  def configuring(:info, {:netman_event, _, {:add, %{scope: :global}}}, data) do
    # Got a global address — proceed to IP check
    transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
  end

  def configuring(:info, {:dhcp_lease_acquired, lease}, data) do
    emit_dhcp_event(data, :lease_acquired, %{lease: lease})
    data = %{data | lease: lease, dhcp_retries: 0}
    transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])
  end

  def configuring(:info, {:dhcp_lease_failed, reason}, data) do
    emit_dhcp_event(data, :lease_failed, %{reason: reason})

    if retryable_dhcp_failure?(reason) and data.dhcp_retries < @max_dhcp_retries do
      retry = data.dhcp_retries + 1
      delay = @dhcp_base_retry_ms * Bitwise.bsl(1, retry - 1)

      Logger.info(
        "DHCP failed for #{data.interface} (attempt #{retry}/#{@max_dhcp_retries}), retrying in #{delay}ms"
      )

      Process.send_after(self(), :retry_dhcp, delay)
      {:keep_state, %{data | dhcp_retries: retry}}
    else
      if not retryable_dhcp_failure?(reason) do
        Logger.warning("DHCP fatal error for #{data.interface}: #{inspect(reason)}")
      else
        Logger.warning(
          "DHCP failed for #{data.interface} after #{@max_dhcp_retries} retries, giving up"
        )
      end

      transition(%{data | error: :dhcp_failed, dhcp_retries: 0}, :configuring, :failed)
    end
  end

  def configuring(:info, :retry_dhcp, data) do
    Logger.info("Retrying DHCP for #{data.interface} (attempt #{data.dhcp_retries})")
    start_dhcp(data)
    {:keep_state, data}
  end

  def configuring(:info, {:netman_event, _, {:link_update, %{carrier: false}}}, data) do
    # Carrier lost during configuration
    Logger.warning("Carrier lost during configuring for #{data.interface}")

    transition(data, :configuring, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def configuring(:state_timeout, :configuring_timeout, data) do
    Logger.warning(
      "Configuration timed out for #{data.interface} after #{@configuring_timeout_ms}ms"
    )

    release_dhcp(data)
    transition(%{data | error: :configuring_timeout, lease: nil}, :configuring, :failed)
  end

  def configuring(:info, {:netman_event, _, {:removed, _}}, data) do
    release_dhcp(data)
    transition(data, :configuring, :unavailable)
  end

  def configuring(:cast, {:update_profile, new_profile}, data) do
    if methods_changed?(data.profile, new_profile) do
      Logger.info("Profile #{data.profile.id} method changed during configuring, restarting")
      release_dhcp(data)

      transition(%{data | profile: new_profile}, :configuring, :deactivating, [
        {:next_event, :internal, :cleanup},
        {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
      ])
    else
      {:keep_state, %{data | profile: new_profile}}
    end
  end

  def configuring(:cast, :deactivate, data) do
    transition(data, :configuring, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
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

    # Only bypass address check when neither protocol expects a global address
    no_global_expected =
      data.profile.ipv4.method == :disabled and
        data.profile.ipv6.method in [:disabled, :link_local]

    if has_global or no_global_expected do
      data = %{data | ip_check_retries: 0}

      transition(data, :ip_check, :activated, [
        {:next_event, :internal, :post_activate}
      ])
    else
      if data.ip_check_retries >= @max_ip_check_retries do
        Logger.warning(
          "IP check for #{data.interface} exhausted #{@max_ip_check_retries} retries, failing"
        )

        release_dhcp(data)

        transition(
          %{data | error: :ip_check_timeout, ip_check_retries: 0, lease: nil},
          :ip_check,
          :failed
        )
      else
        {:keep_state, %{data | ip_check_retries: data.ip_check_retries + 1},
         [{:state_timeout, 2000, :retry_check}]}
      end
    end
  end

  def ip_check(:state_timeout, :retry_check, data) do
    {:keep_state, data, [{:next_event, :internal, :check_ip}]}
  end

  def ip_check(:info, {:netman_event, _, {:link_update, %{carrier: false}}}, data) do
    Logger.warning("Carrier lost during ip_check for #{data.interface}")

    transition(%{data | ip_check_retries: 0}, :ip_check, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def ip_check(:info, {:netman_event, _, {:removed, _}}, data) do
    release_dhcp(data)
    AddressManager.flush(data.interface)
    transition(%{data | ip_check_retries: 0}, :ip_check, :unavailable)
  end

  def ip_check(:cast, :deactivate, data) do
    transition(%{data | ip_check_retries: 0}, :ip_check, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
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
    transition(data, :activated, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def activated(:info, {:netman_event, _, {:remove, %{scope: :global}}}, data) do
    # A global address was removed — check if we still have any
    # Only matters if at least one protocol expects a global address
    needs_global =
      data.profile.ipv4.method != :disabled or
        data.profile.ipv6.method in [:auto, :manual]

    if needs_global do
      addresses = AddressManager.get_addresses(data.interface)
      has_global = Enum.any?(addresses, &(&1.scope == :global))

      if has_global do
        {:keep_state, data}
      else
        Logger.info("All global addresses lost for #{data.interface}, deactivating")

        transition(data, :activated, :deactivating, [
          {:next_event, :internal, :cleanup},
          {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
        ])
      end
    else
      {:keep_state, data}
    end
  end

  def activated(:info, {:dhcp_lease_renewed, lease}, data) do
    emit_dhcp_event(data, :lease_renewed, %{lease: lease})
    {:keep_state, %{data | lease: lease}}
  end

  def activated(:info, {:dhcp_lease_expired, reason}, data) do
    emit_dhcp_event(data, :lease_expired, %{reason: reason})

    transition(data, :activated, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def activated(:info, {:netman_event, _, {:removed, _}}, data) do
    Logger.info("Interface #{data.interface} removed while activated, cleaning up")
    release_dhcp(data)
    reset_dns(data)
    RouteManager.flush(data.interface)
    AddressManager.flush(data.interface)
    transition(%{data | lease: nil}, :activated, :unavailable)
  end

  def activated(:cast, {:update_profile, new_profile}, data) do
    old = data.profile

    if methods_changed?(old, new_profile) do
      # IP method changed — must reconfigure: deactivate then re-activate
      Logger.info("Profile #{old.id} method changed, reconfiguring #{data.interface}")

      transition(%{data | profile: new_profile}, :activated, :deactivating, [
        {:next_event, :internal, :cleanup},
        {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
      ])
    else
      # Non-method change (DNS, priority, gateway, etc.) — update in-place
      data = %{data | profile: new_profile}
      push_dns(data)
      install_routes(data)
      {:keep_state, data}
    end
  end

  def activated(:cast, :deactivate, data) do
    transition(data, :activated, :deactivating, [
      {:next_event, :internal, :cleanup},
      {:state_timeout, @deactivating_timeout_ms, :cleanup_timeout}
    ])
  end

  def activated({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :activated)}}]}
  end

  def activated(_event_type, _event, data), do: {:keep_state, data}

  ## State: deactivating

  def deactivating(:internal, :cleanup, data) do
    release_dhcp(data)
    reset_dns(data)
    AddressManager.flush(data.interface)
    RouteManager.flush(data.interface)
    EventBus.publish("netman:connection:#{data.profile.id}", {:deactivated, data.interface})
    data = %{data | lease: nil}
    transition(data, :deactivating, :disconnected)
  end

  def deactivating(:state_timeout, :cleanup_timeout, data) do
    Logger.warning(
      "Deactivation timed out for #{data.interface}, forcing transition to disconnected"
    )

    data = %{data | lease: nil}
    transition(data, :deactivating, :disconnected)
  end

  def deactivating({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :deactivating)}}]}
  end

  def deactivating(_event_type, _event, data), do: {:keep_state, data}

  ## State: failed

  def failed(:cast, :activate, data) do
    data = %{data | error: nil, dhcp_retries: 0, ip_check_retries: 0}

    transition(data, :failed, :disconnected, [{:next_event, :internal, :auto_activate}])
  end

  def failed(:info, {:netman_event, _, {:link_update, %{carrier: true}}}, data) do
    data = %{data | error: nil, dhcp_retries: 0, ip_check_retries: 0}

    transition(data, :failed, :disconnected, [{:next_event, :internal, :auto_activate}])
  end

  def failed(:cast, :deactivate, data) do
    release_dhcp(data)

    data = %{data | error: nil, lease: nil, dhcp_retries: 0, ip_check_retries: 0}
    transition(data, :failed, :disconnected)
  end

  def failed(:info, {:netman_event, _, {:removed, _}}, data) do
    transition(%{data | error: nil}, :failed, :unavailable)
  end

  def failed({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, state_info(data, :failed)}}]}
  end

  def failed(_event_type, _event, data), do: {:keep_state, data}

  ## Graceful shutdown

  @impl true
  def terminate(_reason, state, data)
      when state in [:activated, :configuring, :ip_check, :deactivating] do
    Logger.info("FSM terminating in #{state} for #{data.interface}, cleaning up")
    release_dhcp(data)
    reset_dns(data)
    AddressManager.flush(data.interface)
    RouteManager.flush(data.interface)
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  ## Internal helpers

  @doc false
  def setup_link(data, link_mod \\ LinkMonitor) do
    with :ok <- maybe_set_mtu(data, link_mod),
         :ok <- do_set_link_up(data, link_mod) do
      :ok
    end
  catch
    :exit, reason -> {:error, {:netlink_exit, reason}}
  end

  defp maybe_set_mtu(%{profile: %{ethernet: %{mtu: nil}}}, _link_mod), do: :ok

  defp maybe_set_mtu(data, link_mod) do
    link_mod.set_mtu(data.interface, data.profile.ethernet.mtu)
  end

  defp do_set_link_up(data, link_mod) do
    link_mod.set_link_up(data.interface)
  end

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
        case parse_cidr(addr) do
          {:ok, ip, prefix} ->
            case AddressManager.add_address(data.interface, ip, prefix) do
              :ok ->
                transition(data, :configuring, :ip_check, [{:next_event, :internal, :check_ip}])

              {:error, reason} ->
                Logger.warning(
                  "Failed to add static IPv4 address for #{data.interface}: #{inspect(reason)}"
                )

                transition(%{data | error: {:address_failed, reason}}, :configuring, :failed)
            end

          {:error, {:invalid_cidr, invalid}} ->
            Logger.warning("Invalid static IPv4 CIDR for #{data.interface}: #{inspect(invalid)}")

            transition(%{data | error: {:invalid_cidr, invalid}}, :configuring, :failed)
        end

      _ ->
        transition(%{data | error: :no_address_configured}, :configuring, :failed)
    end
  end

  defp apply_static_ipv6(data) do
    case data.profile.ipv6 do
      %{method: :manual, address: addr} when is_binary(addr) ->
        case parse_cidr(addr) do
          {:ok, ip, prefix} ->
            case AddressManager.add_address(data.interface, ip, prefix) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "Failed to add static IPv6 address for #{data.interface}: #{inspect(reason)}"
                )
            end

          {:error, {:invalid_cidr, invalid}} ->
            Logger.warning("Invalid static IPv6 CIDR for #{data.interface}: #{inspect(invalid)}")
        end

      _ ->
        :ok
    end
  end

  defp release_dhcp(data) do
    should_release? = data.lease != nil or data.profile.ipv4.method == :auto

    if should_release? and Code.ensure_loaded?(YellowDog.DhcpClient) do
      YellowDog.DhcpClient.release(data.interface)
    end
  end

  defp install_routes(data) do
    metrics = YellowDog.Netman.PolicyEngine.route_metrics([state_info(data, :activated)])
    metric = Map.get(metrics, data.profile.id, 100)

    install_ipv4_route(data, metric)
    install_ipv6_route(data, metric)
  end

  defp install_ipv4_route(data, metric) do
    case data.profile.ipv4 do
      %{gateway: gw} when is_binary(gw) ->
        RouteManager.add_route(%{
          destination: "default",
          gateway: gw,
          interface: data.interface,
          metric: metric,
          family: :inet
        })

      _ ->
        :ok
    end
  end

  defp install_ipv6_route(data, metric) do
    case data.profile.ipv6 do
      %{gateway: gw} when is_binary(gw) ->
        RouteManager.add_route(%{
          destination: "default",
          gateway: gw,
          interface: data.interface,
          metric: metric,
          family: :inet6
        })

      _ ->
        :ok
    end
  end

  defp push_dns(data) do
    profile_dns = (data.profile.ipv4.dns || []) ++ (data.profile.ipv6.dns || [])

    profile_servers =
      Enum.flat_map(profile_dns, fn s ->
        case :inet.parse_address(String.to_charlist(s)) do
          {:ok, ip} ->
            [ip]

          {:error, _} ->
            Logger.warning(
              "Invalid DNS server address #{inspect(s)} for #{data.interface}, skipping"
            )

            []
        end
      end)

    # Include DHCP-provided DNS servers (already IP tuples)
    lease_dns =
      case data.lease do
        %{dns_servers: servers} when is_list(servers) -> servers
        _ -> []
      end

    # Profile DNS takes precedence, DHCP DNS is appended
    servers = profile_servers ++ lease_dns
    servers = Enum.uniq(servers)

    if servers != [] and Code.ensure_loaded?(YellowDog.Resolved) do
      try do
        apply(YellowDog.Resolved, :set_link_dns, [
          data.interface,
          %{
            servers: servers,
            search: collect_dns_search(data),
            priority: data.profile.autoconnect_priority
          }
        ])
      rescue
        e ->
          Logger.warning("Failed to push DNS for #{data.interface}: #{inspect(e)}")
          :ok
      end
    else
      :ok
    end
  end

  defp reset_dns(data) do
    if Code.ensure_loaded?(YellowDog.Resolved) do
      try do
        apply(YellowDog.Resolved, :reset_link_dns, [data.interface])
      rescue
        e ->
          Logger.warning("Failed to reset DNS for #{data.interface}: #{inspect(e)}")
          :ok
      end
    else
      :ok
    end
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
      dns: collect_dns_strings(data)
    }
  end

  defp collect_dns_strings(data) do
    profile_dns = (data.profile.ipv4.dns || []) ++ (data.profile.ipv6.dns || [])

    lease_dns =
      case data.lease do
        %{dns_servers: servers} when is_list(servers) ->
          Enum.map(servers, fn ip ->
            ip |> :inet.ntoa() |> List.to_string()
          end)

        _ ->
          []
      end

    Enum.uniq(profile_dns ++ lease_dns)
  end

  defp collect_dns_search(data) do
    ipv4_search = Map.get(data.profile.ipv4, :dns_search, []) || []
    ipv6_search = Map.get(data.profile.ipv6, :dns_search, []) || []
    Enum.uniq(ipv4_search ++ ipv6_search)
  end

  defp emit_dhcp_event(data, action, metadata) do
    :telemetry.execute(
      [:yellow_dog, :netman, :dhcp, action],
      %{count: 1},
      Map.merge(%{interface: data.interface, profile_id: data.profile.id}, metadata)
    )
  end

  # Fatal DHCP failures that should not be retried
  defp retryable_dhcp_failure?(:dhcp_client_not_available), do: false
  defp retryable_dhcp_failure?({:mac_detection_failed, _}), do: false
  defp retryable_dhcp_failure?(_), do: true

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix] ->
        case Integer.parse(prefix) do
          {n, ""} when n >= 0 and n <= 128 ->
            {:ok, addr, n}

          _ ->
            default = default_prefix(addr)
            Logger.warning("Invalid CIDR prefix in #{inspect(cidr)}, defaulting to /#{default}")
            {:ok, addr, default}
        end

      [addr] ->
        default = default_prefix(addr)
        Logger.warning("No CIDR prefix in #{inspect(addr)}, defaulting to /#{default}")
        {:ok, addr, default}

      _ ->
        {:error, {:invalid_cidr, cidr}}
    end
  end

  defp default_prefix(addr) do
    if String.contains?(addr, ":"), do: 128, else: 32
  end

  defp methods_changed?(old_profile, new_profile) do
    old_profile.ipv4.method != new_profile.ipv4.method or
      old_profile.ipv6.method != new_profile.ipv6.method
  end
end
