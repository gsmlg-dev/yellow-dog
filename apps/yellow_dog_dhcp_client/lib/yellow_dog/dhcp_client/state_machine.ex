defmodule YellowDog.DhcpClient.StateMachine do
  @moduledoc """
  DHCP client state machine implementing the full DORA lifecycle.

  Uses `:gen_statem` with `handle_event_function` callback mode.

  ## States

      INIT -> SELECTING -> REQUESTING -> BOUND -> RENEWING -> REBINDING
        ^                                  ^        |           |
        |                                  |       T1          T2
        |                                  +--------+           |
        +------------------------------------------------------+

  Retransmission follows RFC 2131 Section 4.1: exponential backoff starting at 2s,
  doubling to max 64s, with +/-1s random jitter.
  """

  @behaviour :gen_statem

  alias YellowDog.DhcpClient.{DAD, DhcpSocket, LeaseStore}

  require Logger

  @initial_retransmit_ms 2_000
  @max_retransmit_ms 64_000
  @max_request_attempts 4
  @default_selection_window_ms 1_000
  @nak_backoff_ms 1_000

  defstruct [
    :interface,
    :mac,
    :socket_pid,
    :store_pid,
    :os_module,
    :xid,
    :lease,
    :start_time,
    :state_entered_at,
    offers: [],
    retransmit_count: 0,
    config: %{}
  ]

  @type t :: %__MODULE__{
          interface: String.t(),
          mac: binary(),
          socket_pid: pid() | GenServer.server(),
          store_pid: GenServer.server() | nil,
          os_module: module() | nil,
          xid: non_neg_integer(),
          offers: [map()],
          lease: map() | nil,
          retransmit_count: non_neg_integer(),
          config: map(),
          start_time: integer(),
          state_entered_at: integer() | nil
        }

  # --- Public API ---

  @doc "Starts the DHCP client state machine."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    interface = Keyword.fetch!(opts, :interface)
    mac = Keyword.fetch!(opts, :mac)
    socket_pid = Keyword.fetch!(opts, :socket_pid)
    config = Keyword.get(opts, :config, %{})
    store_pid = Keyword.get(opts, :store_pid)
    os_module = Keyword.get(opts, :os_module)
    name = Keyword.get(opts, :name)

    data = %__MODULE__{
      interface: interface,
      mac: mac,
      socket_pid: socket_pid,
      store_pid: store_pid,
      os_module: os_module,
      config: config,
      start_time: System.monotonic_time(:millisecond)
    }

    start_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, data, start_opts)
  end

  @doc "Triggers a DHCPRELEASE and returns to INIT."
  @spec release(pid()) :: :ok
  def release(pid) do
    :gen_statem.cast(pid, :release)
  end

  @doc "Returns the current state and data."
  @spec status(pid()) :: {atom(), t()}
  def status(pid) do
    :gen_statem.call(pid, :status)
  end

  @doc "Returns the current lease, or `nil` if not bound."
  @spec lease(pid()) :: map() | nil
  def lease(pid) do
    :gen_statem.call(pid, :lease)
  end

  # --- gen_statem callbacks ---

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(data) do
    {:ok, :init, data}
  end

  # ---- INIT ----

  @impl true
  def handle_event(:enter, _old_state, :init, data) do
    now = System.monotonic_time(:millisecond)
    data = %{data | xid: generate_xid(), retransmit_count: 0, offers: [], lease: nil, start_time: now}
    data = track_state_entry(data, :init)
    send_discover(data)

    actions = [retransmit_timeout_action(data.retransmit_count)]
    {:keep_state, data, actions}
  end

  def handle_event(:info, {:dhcp_rx, packet}, :init, data) do
    case parse_reply(packet) do
      {:offer, lease} ->
        emit_packet_rx(data, :offer, lease)
        {:next_state, :selecting, %{data | offers: [lease]}}

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :retransmit}, :retransmit, :init, data) do
    data = %{data | xid: generate_xid(), retransmit_count: data.retransmit_count + 1}
    send_discover(data)

    actions = [retransmit_timeout_action(data.retransmit_count)]
    {:keep_state, data, actions}
  end

  # ---- SELECTING ----

  def handle_event(:enter, _old_state, :selecting, data) do
    data = track_state_entry(data, :selecting)
    window_ms = Map.get(data.config, :selection_window_ms, @default_selection_window_ms)
    actions = [{{:timeout, :selection}, window_ms, :select}]
    {:keep_state, data, actions}
  end

  def handle_event(:info, {:dhcp_rx, packet}, :selecting, data) do
    case parse_reply(packet) do
      {:offer, lease} ->
        emit_packet_rx(data, :offer, lease)
        {:keep_state, %{data | offers: [lease | data.offers]}}

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :selection}, :select, :selecting, data) do
    chosen = select_best_offer(data.offers)
    {:next_state, :requesting, %{data | lease: chosen, retransmit_count: 0}}
  end

  # ---- REQUESTING ----

  def handle_event(:enter, _old_state, :requesting, data) do
    data = track_state_entry(data, :requesting)
    send_request_broadcast(data)

    actions = [retransmit_timeout_action(0)]
    {:keep_state, data, actions}
  end

  def handle_event(:info, {:dhcp_rx, packet}, :requesting, data) do
    case parse_reply(packet) do
      {:ack, lease} ->
        emit_packet_rx(data, :ack, lease)
        maybe_dad_then_bound(data, lease)

      {:nak, _reason} ->
        emit_packet_rx(data, :nak, nil)
        actions = [{{:timeout, :nak_backoff}, @nak_backoff_ms, :go_init}]
        {:keep_state_and_data, actions}

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :nak_backoff}, :go_init, :requesting, data) do
    {:next_state, :init, data}
  end

  def handle_event({:timeout, :dad_backoff}, :go_init, :requesting, data) do
    {:next_state, :init, data}
  end

  def handle_event({:timeout, :retransmit}, :retransmit, :requesting, data) do
    count = data.retransmit_count + 1

    if count >= @max_request_attempts do
      {:next_state, :init, data}
    else
      data = %{data | retransmit_count: count}
      send_request_broadcast(data)
      actions = [retransmit_timeout_action(count)]
      {:keep_state, data, actions}
    end
  end

  # ---- BOUND ----

  def handle_event(:enter, old_state, :bound, data) do
    data = track_state_entry(data, :bound)

    is_renewal = old_state in [:renewing, :rebinding]

    if is_renewal do
      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :renewed],
        %{lease_time_s: data.lease.lease_time},
        %{interface: data.interface, ip: format_ip(data.lease.ip)}
      )
    else
      handshake_ms = System.monotonic_time(:millisecond) - data.start_time

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: data.lease.lease_time, handshake_duration_ms: handshake_ms},
        %{
          interface: data.interface,
          ip: format_ip(data.lease.ip),
          server: format_ip(data.lease.server_ip)
        }
      )
    end

    persist_lease(data)
    apply_os_lease(data)

    t1_ms = (data.lease.t1 || div(data.lease.lease_time, 2)) * 1_000
    t2_ms = (data.lease.t2 || div(data.lease.lease_time * 7, 8)) * 1_000

    actions = [
      {{:timeout, :t1}, t1_ms, :renew},
      {{:timeout, :t2}, t2_ms, :rebind}
    ]

    {:keep_state, data, actions}
  end

  def handle_event({:timeout, :t1}, :renew, :bound, data) do
    {:next_state, :renewing, data}
  end

  def handle_event({:timeout, :t2}, :rebind, :bound, data) do
    {:next_state, :rebinding, data}
  end

  def handle_event(:cast, :release, :bound, data) do
    send_release(data)
    deconfigure_os(data)
    {:next_state, :init, %{data | lease: nil}}
  end

  def handle_event(:info, :interface_down, :bound, data) do
    deconfigure_os(data)
    {:next_state, :init, %{data | lease: nil}}
  end

  # ---- RENEWING ----

  def handle_event(:enter, _old_state, :renewing, data) do
    data = track_state_entry(data, :renewing)
    data = %{data | retransmit_count: 0}
    send_request_unicast(data)

    remaining_ms = remaining_until_t2(data)
    interval = max(div(remaining_ms, 2), 1_000)
    actions = [{{:timeout, :retransmit}, interval, :retransmit}]
    {:keep_state, data, actions}
  end

  def handle_event(:info, {:dhcp_rx, packet}, :renewing, data) do
    case parse_reply(packet) do
      {:ack, lease} ->
        emit_packet_rx(data, :ack, lease)
        {:next_state, :bound, %{data | lease: lease}}

      {:nak, _reason} ->
        emit_packet_rx(data, :nak, nil)
        deconfigure_os(data)
        {:next_state, :init, %{data | lease: nil}}

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :t2}, :rebind, :renewing, data) do
    {:next_state, :rebinding, data}
  end

  def handle_event({:timeout, :retransmit}, :retransmit, :renewing, data) do
    send_request_unicast(data)
    remaining_ms = remaining_until_t2(data)
    interval = max(div(remaining_ms, 2), 1_000)
    actions = [{{:timeout, :retransmit}, interval, :retransmit}]
    {:keep_state_and_data, actions}
  end

  # ---- REBINDING ----

  def handle_event(:enter, _old_state, :rebinding, data) do
    data = track_state_entry(data, :rebinding)
    data = %{data | retransmit_count: 0}
    send_request_broadcast(data)

    remaining_ms = remaining_until_expiry(data)
    interval = max(div(remaining_ms, 2), 1_000)

    actions = [
      {{:timeout, :retransmit}, interval, :retransmit},
      {{:timeout, :lease_expired}, remaining_ms, :expired}
    ]

    {:keep_state, data, actions}
  end

  def handle_event(:info, {:dhcp_rx, packet}, :rebinding, data) do
    case parse_reply(packet) do
      {:ack, lease} ->
        emit_packet_rx(data, :ack, lease)
        {:next_state, :bound, %{data | lease: lease}}

      {:nak, _reason} ->
        emit_packet_rx(data, :nak, nil)
        deconfigure_os(data)
        {:next_state, :init, %{data | lease: nil}}

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :lease_expired}, :expired, :rebinding, data) do
    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :lease, :expired],
      %{},
      %{interface: data.interface, ip: format_ip(data.lease.ip)}
    )

    deconfigure_os(data)
    {:next_state, :init, %{data | lease: nil}}
  end

  def handle_event({:timeout, :retransmit}, :retransmit, :rebinding, data) do
    send_request_broadcast(data)
    remaining_ms = remaining_until_expiry(data)
    interval = max(div(remaining_ms, 2), 1_000)
    actions = [{{:timeout, :retransmit}, interval, :retransmit}]
    {:keep_state_and_data, actions}
  end

  # ---- Common events ----

  def handle_event(:cast, :release, _state, data) do
    if data.lease do
      send_release(data)
      deconfigure_os(data)
    end

    {:next_state, :init, %{data | lease: nil}}
  end

  def handle_event(:info, :interface_down, _state, data) do
    if data.lease, do: deconfigure_os(data)
    {:next_state, :init, %{data | lease: nil}}
  end

  def handle_event({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, {state, data}}]}
  end

  def handle_event({:call, from}, :lease, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.lease}]}
  end

  def handle_event(_event_type, _event, _state, _data) do
    :keep_state_and_data
  end

  # --- Offer selection ---

  @doc """
  Selects the best offer from the accumulated list.

  Priority:
  1. Offers with Yellow Dog PEN in Option 125 (`yellowdog_server: true`)
  2. Offers from known servers
  3. First offer received (FIFO)
  """
  @spec select_best_offer([map()]) :: map()
  def select_best_offer([single]), do: single

  def select_best_offer(offers) when is_list(offers) do
    reversed = Enum.reverse(offers)

    Enum.find(reversed, fn o -> Map.get(o, :yellowdog_server, false) end) ||
      Enum.find(reversed, fn o -> Map.get(o, :known_server, false) end) ||
      List.first(reversed)
  end

  # --- Packet helpers ---

  defp send_discover(data) do
    packet = build_discover(data)
    :telemetry.execute([:yellow_dog, :dhcp_client, :packet, :tx], %{}, %{interface: data.interface, type: :discover})
    broadcast_packet(data, packet, :discover)
  end

  defp send_request_broadcast(data) do
    packet = build_request(data)
    :telemetry.execute([:yellow_dog, :dhcp_client, :packet, :tx], %{}, %{interface: data.interface, type: :request})
    broadcast_packet(data, packet, :request)
  end

  defp send_request_unicast(data) do
    packet = build_request(data)
    :telemetry.execute([:yellow_dog, :dhcp_client, :packet, :tx], %{}, %{interface: data.interface, type: :request})
    unicast_packet(data, data.lease.server_ip, packet, :request)
  end

  defp send_release(data) do
    packet = build_release(data)
    :telemetry.execute([:yellow_dog, :dhcp_client, :packet, :tx], %{}, %{interface: data.interface, type: :release})
    unicast_packet(data, data.lease.server_ip, packet, :release)
  end

  defp maybe_dad_then_bound(data, lease) do
    dad_enabled = Map.get(data.config, :dad_enabled, true)

    if dad_enabled do
      dad_opts = [
        probes: Map.get(data.config, :dad_probes, 3),
        wait_ms: Map.get(data.config, :dad_wait_ms, 2_000)
      ]

      case DAD.check(data.socket_pid, lease.ip, dad_opts) do
        :ok ->
          {:next_state, :bound, %{data | lease: lease}}

        {:conflict, _mac} ->
          send_decline(data, lease)
          backoff_ms = Map.get(data.config, :dad_backoff_ms, 10_000)
          actions = [{{:timeout, :dad_backoff}, backoff_ms, :go_init}]
          {:keep_state, data, actions}
      end
    else
      {:next_state, :bound, %{data | lease: lease}}
    end
  end

  defp send_decline(data, lease) do
    packet = build_decline(data, lease)
    :telemetry.execute([:yellow_dog, :dhcp_client, :packet, :tx], %{}, %{interface: data.interface, type: :decline})
    broadcast_packet(data, packet, :decline)
  end

  defp broadcast_packet(data, packet, type) do
    case DhcpSocket.send_broadcast(data.socket_pid, packet) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "DHCP client #{data.interface}: failed to broadcast #{type}: #{inspect(reason)}"
        )
    end
  end

  defp unicast_packet(data, dest_ip, packet, type) do
    case DhcpSocket.send_unicast(data.socket_pid, dest_ip, packet) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "DHCP client #{data.interface}: failed to unicast #{type} to #{format_ip(dest_ip)}: #{inspect(reason)}"
        )
    end
  end

  # --- Packet building (delegates to Packet module if available, inline fallback) ---

  defp build_discover(data) do
    packet_mod().build_discover(data.mac, data.xid, Map.to_list(data.config))
  end

  defp build_request(data) do
    packet_mod().build_request(
      data.mac,
      data.xid,
      data.lease.server_ip,
      data.lease.ip,
      Map.to_list(data.config)
    )
  end

  defp build_release(data) do
    packet_mod().build_release(data.mac, data.xid, data.lease.server_ip, data.lease.ip)
  end

  defp build_decline(data, lease) do
    packet_mod().build_decline(data.mac, data.xid, lease.server_ip, lease.ip)
  end

  defp parse_reply(packet) do
    packet_mod().parse_reply(packet)
  end

  defp packet_mod do
    Application.get_env(:yellow_dog_dhcp_client, :packet_module, YellowDog.DhcpClient.Packet)
  end

  # --- Lease persistence and OS integration ---

  defp persist_lease(%{store_pid: nil}), do: :ok

  defp persist_lease(%{store_pid: store_pid, interface: interface, lease: lease}) do
    LeaseStore.store(store_pid, interface, lease)
  rescue
    e ->
      Logger.warning("Failed to persist lease for #{interface}: #{Exception.message(e)}")
      :ok
  end

  defp apply_os_lease(%{os_module: nil}), do: :ok

  defp apply_os_lease(%{os_module: mod, interface: interface, lease: lease}) do
    case mod.apply_lease(interface, lease) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("OS integration apply_lease failed for #{interface}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("OS integration crashed for #{interface}: #{Exception.message(e)}")
      :ok
  end

  defp deconfigure_os(%{os_module: nil}), do: :ok

  defp deconfigure_os(%{os_module: mod, interface: interface}) do
    case mod.deconfigure(interface) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("OS integration deconfigure failed for #{interface}: #{inspect(reason)}")

        :ok
    end
  rescue
    e ->
      Logger.warning("OS deconfigure crashed for #{interface}: #{Exception.message(e)}")
      :ok
  end

  # --- Timer helpers ---

  defp retransmit_timeout_action(retransmit_count) do
    base = min(@initial_retransmit_ms * Integer.pow(2, retransmit_count), @max_retransmit_ms)
    jitter = :rand.uniform(2_001) - 1_001
    delay = max(base + jitter, 500)
    {{:timeout, :retransmit}, delay, :retransmit}
  end

  defp remaining_until_t2(data) do
    t2_s = data.lease.t2 || div(data.lease.lease_time * 7, 8)
    obtained_ms = DateTime.to_unix(data.lease.obtained_at, :millisecond)
    deadline = obtained_ms + t2_s * 1_000
    max(deadline - System.system_time(:millisecond), 1_000)
  end

  defp remaining_until_expiry(data) do
    obtained_ms = DateTime.to_unix(data.lease.obtained_at, :millisecond)
    deadline = obtained_ms + data.lease.lease_time * 1_000
    max(deadline - System.system_time(:millisecond), 1_000)
  end

  # --- Telemetry ---

  # Emits a state change telemetry event and returns data updated with the new
  # state entry timestamp so the next state transition can report an accurate
  # duration_in_state_ms.
  defp track_state_entry(data, to_state) do
    now = System.monotonic_time(:millisecond)

    duration_ms =
      if data.state_entered_at, do: now - data.state_entered_at, else: 0

    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :state, :change],
      %{duration_in_state_ms: duration_ms},
      %{interface: data.interface, to: to_state}
    )

    %{data | state_entered_at: now}
  end

  defp emit_packet_rx(data, type, lease) do
    server =
      if lease && Map.has_key?(lease, :server_ip),
        do: format_ip(lease.server_ip),
        else: "unknown"

    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :packet, :rx],
      %{},
      %{interface: data.interface, type: type, server: server}
    )
  end

  defp format_ip(nil), do: "0.0.0.0"

  defp format_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp format_ip(ip), do: to_string(ip)

  defp generate_xid do
    DHCP.SecureRandom.generate_dhcpv4_xid()
  end
end
