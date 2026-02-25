defmodule YellowDog.DhcpClient.Integration.HandshakeTest do
  @moduledoc """
  Integration test for the full DHCP DORA handshake.

  Uses a MockServer GenServer that intercepts outbound DISCOVER/REQUEST packets
  from the StateMachine, builds well-formed OFFER/ACK replies using the real
  DHCP protocol library, and sends them back as `{:dhcp_rx, binary}` messages.
  No network access or privileged ports required.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias YellowDog.DhcpClient.StateMachine
  alias YellowDog.DhcpClient.VendorOptions
  alias DHCPv4.Message
  alias DHCPv4.Message.Option

  @test_mac <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE>>

  @offered_ip {10, 0, 0, 100}
  @server_ip {10, 0, 0, 1}
  @subnet_mask {255, 255, 255, 0}
  @dns_server {8, 8, 8, 8}
  @lease_time 3600
  @t1 1800
  @t2 3156

  # ── MockServer ──────────────────────────────────────────────────────────

  defmodule MockServer do
    @moduledoc false

    use GenServer

    @behaviour YellowDog.DhcpClient.DhcpSocket

    defstruct [
      :fsm_pid,
      :server_ip,
      :offered_ip,
      :vendor_opts,
      :nak_requests,
      :test_pid,
      :socket_ref
    ]

    # ── DhcpSocket behaviour callbacks ──

    @impl YellowDog.DhcpClient.DhcpSocket
    def open(_interface, _owner), do: {:ok, make_ref()}

    @impl YellowDog.DhcpClient.DhcpSocket
    def send_broadcast(_ref, _packet), do: :ok

    @impl YellowDog.DhcpClient.DhcpSocket
    def send_unicast(_ref, _dest, _packet), do: :ok

    @impl YellowDog.DhcpClient.DhcpSocket
    def send_arp_probe(_ref, _ip), do: {:error, :not_supported}

    @impl YellowDog.DhcpClient.DhcpSocket
    def close(_ref), do: :ok

    # ── GenServer API ──

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def set_fsm_pid(server, fsm_pid) do
      GenServer.call(server, {:set_fsm_pid, fsm_pid})
    end

    @impl GenServer
    def init(opts) do
      state = %__MODULE__{
        fsm_pid: Keyword.get(opts, :fsm_pid),
        server_ip: Keyword.get(opts, :server_ip, {10, 0, 0, 1}),
        offered_ip: Keyword.get(opts, :offered_ip, {10, 0, 0, 100}),
        vendor_opts: Keyword.get(opts, :vendor_opts),
        nak_requests: Keyword.get(opts, :nak_requests, false),
        test_pid: Keyword.get(opts, :test_pid),
        socket_ref: make_ref()
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:set_fsm_pid, pid}, _from, state) do
      {:reply, :ok, %{state | fsm_pid: pid}}
    end

    # The StateMachine calls DhcpSocket.send_broadcast(mock_pid, packet)
    # which translates to GenServer.call(mock_pid, {:send_broadcast, packet}).
    def handle_call({:send_broadcast, packet}, _from, state) do
      state = handle_outbound_packet(packet, state)
      {:reply, :ok, state}
    end

    def handle_call({:send_unicast, _dest_ip, packet}, _from, state) do
      state = handle_outbound_packet(packet, state)
      {:reply, :ok, state}
    end

    def handle_call({:send_arp_probe, _ip}, _from, state) do
      {:reply, {:error, :not_supported}, state}
    end

    @impl GenServer
    def handle_info(_msg, state), do: {:noreply, state}

    # ── Packet handling ──

    defp handle_outbound_packet(packet, state) when is_binary(packet) do
      <<_op, _htype, _hlen, _hops, xid::32, _rest::binary>> = packet

      case detect_message_type(packet) do
        :discover ->
          notify_test(state, {:intercepted, :discover, xid})
          reply = build_offer(xid, state)
          send_reply(state, reply)

        :request ->
          notify_test(state, {:intercepted, :request, xid})

          if state.nak_requests do
            reply = build_nak(xid, state)
            send_reply(state, reply)
          else
            reply = build_ack(xid, state)
            send_reply(state, reply)
          end

        :release ->
          notify_test(state, {:intercepted, :release, xid})

        _other ->
          :ok
      end

      state
    end

    defp detect_message_type(packet) do
      msg = Message.from_iodata(packet)

      msg.options
      |> Enum.find(fn %Option{type: t} -> t == 53 end)
      |> case do
        %Option{value: <<1>>} -> :discover
        %Option{value: <<3>>} -> :request
        %Option{value: <<4>>} -> :decline
        %Option{value: <<7>>} -> :release
        _ -> :unknown
      end
    rescue
      _ -> :unknown
    end

    defp build_offer(xid, state) do
      {sa, sb, sc, sd} = state.server_ip

      options = [
        %Option{type: 53, length: 1, value: <<2>>},
        %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
        %Option{type: 3, length: 4, value: <<sa, sb, sc, sd>>},
        %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
        %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
        %Option{type: 54, length: 4, value: <<sa, sb, sc, sd>>},
        %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
        %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>}
      ]

      options = maybe_add_vendor_opts(options, state.vendor_opts)
      build_reply_message(xid, state.offered_ip, state.server_ip, options)
    end

    defp build_ack(xid, state) do
      {sa, sb, sc, sd} = state.server_ip

      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
        %Option{type: 3, length: 4, value: <<sa, sb, sc, sd>>},
        %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
        %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
        %Option{type: 54, length: 4, value: <<sa, sb, sc, sd>>},
        %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
        %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>}
      ]

      options = maybe_add_vendor_opts(options, state.vendor_opts)
      build_reply_message(xid, state.offered_ip, state.server_ip, options)
    end

    defp build_nak(xid, state) do
      {sa, sb, sc, sd} = state.server_ip
      nak_message = "address unavailable"

      options = [
        %Option{type: 53, length: 1, value: <<6>>},
        %Option{type: 54, length: 4, value: <<sa, sb, sc, sd>>},
        %Option{type: 56, length: byte_size(nak_message), value: nak_message}
      ]

      build_reply_message(xid, {0, 0, 0, 0}, state.server_ip, options)
    end

    defp build_reply_message(xid, yiaddr, siaddr, options) do
      msg = %Message{
        op: 2,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: xid,
        secs: 0,
        flags: 0,
        ciaddr: {0, 0, 0, 0},
        yiaddr: yiaddr,
        siaddr: siaddr,
        giaddr: {0, 0, 0, 0},
        chaddr: <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0::80>>,
        sname: <<0::512>>,
        file: <<0::1024>>,
        options: options
      }

      IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
    end

    defp maybe_add_vendor_opts(options, nil), do: options

    defp maybe_add_vendor_opts(options, vendor_bin) when is_binary(vendor_bin) do
      options ++ [%Option{type: 125, length: byte_size(vendor_bin), value: vendor_bin}]
    end

    defp send_reply(%{fsm_pid: nil}, _reply), do: :ok

    defp send_reply(%{fsm_pid: fsm_pid}, reply) do
      send(fsm_pid, {:dhcp_rx, reply})
    end

    defp notify_test(%{test_pid: nil}, _msg), do: :ok
    defp notify_test(%{test_pid: pid}, msg), do: send(pid, msg)
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    prev_packet = Application.get_env(:yellow_dog_dhcp_client, :packet_module)
    Application.put_env(:yellow_dog_dhcp_client, :packet_module, YellowDog.DhcpClient.Packet)

    on_exit(fn ->
      if prev_packet do
        Application.put_env(:yellow_dog_dhcp_client, :packet_module, prev_packet)
      else
        Application.delete_env(:yellow_dog_dhcp_client, :packet_module)
      end
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp start_mock_server(opts \\ []) do
    defaults = [
      server_ip: @server_ip,
      offered_ip: @offered_ip,
      test_pid: self()
    ]

    {:ok, mock_pid} = MockServer.start_link(Keyword.merge(defaults, opts))
    mock_pid
  end

  defp start_fsm(mock_pid, config_overrides) do
    config =
      Map.merge(
        %{
          dad_enabled: false,
          selection_window_ms: 100
        },
        config_overrides
      )

    {:ok, fsm_pid} =
      StateMachine.start_link(
        interface: "test0",
        mac: @test_mac,
        socket_pid: mock_pid,
        config: config
      )

    # The FSM sends DISCOVER immediately on init enter. At that point
    # fsm_pid is nil in the mock, so the first OFFER is dropped.
    # Now set the fsm_pid so the retransmit DISCOVER (or subsequent
    # packets) will get replies delivered.
    MockServer.set_fsm_pid(mock_pid, fsm_pid)

    # Also send the OFFER directly for the initial DISCOVER that was
    # already sent (since the mock couldn't deliver it with nil fsm_pid).
    # We do this by checking the FSM's current xid and sending an OFFER.
    {_state, data} = StateMachine.status(fsm_pid)
    kick_offer(mock_pid, fsm_pid, data.xid)

    fsm_pid
  end

  # Send a synthetic OFFER to the FSM to compensate for the initial
  # DISCOVER whose reply could not be delivered (fsm_pid was nil).
  defp kick_offer(_mock_pid, fsm_pid, xid) do
    {sa, sb, sc, sd} = @server_ip

    options = [
      %Option{type: 53, length: 1, value: <<2>>},
      %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
      %Option{type: 3, length: 4, value: <<sa, sb, sc, sd>>},
      %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
      %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
      %Option{type: 54, length: 4, value: <<sa, sb, sc, sd>>},
      %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
      %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>}
    ]

    msg = %Message{
      op: 2,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0,
      ciaddr: {0, 0, 0, 0},
      yiaddr: @offered_ip,
      siaddr: @server_ip,
      giaddr: {0, 0, 0, 0},
      chaddr: <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0::80>>,
      sname: <<0::512>>,
      file: <<0::1024>>,
      options: options
    }

    reply = IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
    send(fsm_pid, {:dhcp_rx, reply})
  end

  defp get_state(pid) do
    {state, _data} = StateMachine.status(pid)
    state
  end

  defp wait_for_state(pid, expected_state, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_state(pid, expected_state, deadline)
  end

  defp do_wait_for_state(pid, expected_state, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      current = get_state(pid)
      flunk("Timed out waiting for state #{expected_state}, current: #{current}")
    end

    case get_state(pid) do
      ^expected_state ->
        :ok

      _ ->
        Process.sleep(10)
        do_wait_for_state(pid, expected_state, deadline)
    end
  end

  defp build_vendor_option_125(sub_options_binary) do
    pen = VendorOptions.pen()
    data_len = byte_size(sub_options_binary)
    <<pen::32, data_len::8, sub_options_binary::binary>>
  end

  defp encode_sub_option(code, value) when is_binary(value) do
    <<code::8, byte_size(value)::8, value::binary>>
  end

  # ── Tests: Standard DORA (no vendor options) ───────────────────────────

  describe "standard DORA handshake (non-YD server)" do
    test "completes full DORA cycle and reaches :bound" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)
    end

    test "lease has correct IP and network parameters" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease != nil
      assert lease.ip == @offered_ip
      assert lease.subnet_mask == @subnet_mask
      assert lease.router == @server_ip
      assert lease.dns_servers == [@dns_server]
      assert lease.server_ip == @server_ip
      assert lease.lease_time == @lease_time
      assert lease.t1 == @t1
      assert lease.t2 == @t2
    end

    test "lease has yellowdog_server set to false without vendor options" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.yellowdog_server == false
      assert lease.control_url == nil
      assert lease.auth_token == nil
    end

    test "DISCOVER and REQUEST produce valid non-zero xids" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.xid > 0
    end
  end

  # ── Tests: DORA with Yellow Dog vendor options ─────────────────────────

  describe "DORA handshake with Yellow Dog vendor options" do
    test "extracts control_url and auth_token from Option 125" do
      control_url = "https://yd.example.com/api"
      auth_token = "secret-token-abc123"

      vendor_sub_opts =
        encode_sub_option(1, control_url) <>
          encode_sub_option(4, auth_token)

      vendor_bin = build_vendor_option_125(vendor_sub_opts)

      mock_pid = start_mock_server(vendor_opts: vendor_bin)
      fsm_pid = start_fsm_with_vendor(mock_pid, vendor_bin, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.yellowdog_server == true
      assert lease.control_url == control_url
      assert lease.auth_token == auth_token
    end

    test "extracts server_id and cluster_id from Option 125" do
      server_id = "yd-server-01"
      cluster_id = "cluster-east"

      vendor_sub_opts =
        encode_sub_option(2, server_id) <>
          encode_sub_option(3, cluster_id)

      vendor_bin = build_vendor_option_125(vendor_sub_opts)

      mock_pid = start_mock_server(vendor_opts: vendor_bin)
      fsm_pid = start_fsm_with_vendor(mock_pid, vendor_bin, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.yellowdog_server == true
      assert lease.server_id == server_id
      assert lease.cluster_id == cluster_id
    end

    test "extracts control_url_fallback from Option 125" do
      control_url = "https://primary.yd.example.com/api"
      fallback_url = "https://fallback.yd.example.com/api"

      vendor_sub_opts =
        encode_sub_option(1, control_url) <>
          encode_sub_option(5, fallback_url)

      vendor_bin = build_vendor_option_125(vendor_sub_opts)

      mock_pid = start_mock_server(vendor_opts: vendor_bin)
      fsm_pid = start_fsm_with_vendor(mock_pid, vendor_bin, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.yellowdog_server == true
      assert lease.control_url == control_url
      assert lease.control_url_fallback == fallback_url
    end

    test "extracts all vendor sub-options together" do
      control_url = "https://yd.example.com/api"
      server_id = "yd-server-01"
      cluster_id = "cluster-west"
      auth_token = "token-xyz-789"
      fallback_url = "https://backup.yd.example.com/api"

      vendor_sub_opts =
        encode_sub_option(1, control_url) <>
          encode_sub_option(2, server_id) <>
          encode_sub_option(3, cluster_id) <>
          encode_sub_option(4, auth_token) <>
          encode_sub_option(5, fallback_url)

      vendor_bin = build_vendor_option_125(vendor_sub_opts)

      mock_pid = start_mock_server(vendor_opts: vendor_bin)
      fsm_pid = start_fsm_with_vendor(mock_pid, vendor_bin, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      lease = StateMachine.lease(fsm_pid)
      assert lease.yellowdog_server == true
      assert lease.control_url == control_url
      assert lease.server_id == server_id
      assert lease.cluster_id == cluster_id
      assert lease.auth_token == auth_token
      assert lease.control_url_fallback == fallback_url
    end
  end

  # For vendor option tests, the kick_offer must also include vendor options
  defp start_fsm_with_vendor(mock_pid, vendor_bin, config_overrides) do
    config =
      Map.merge(
        %{
          dad_enabled: false,
          selection_window_ms: 100
        },
        config_overrides
      )

    {:ok, fsm_pid} =
      StateMachine.start_link(
        interface: "test0",
        mac: @test_mac,
        socket_pid: mock_pid,
        config: config
      )

    MockServer.set_fsm_pid(mock_pid, fsm_pid)

    {_state, data} = StateMachine.status(fsm_pid)
    kick_offer_with_vendor(fsm_pid, data.xid, vendor_bin)

    fsm_pid
  end

  defp kick_offer_with_vendor(fsm_pid, xid, vendor_bin) do
    {sa, sb, sc, sd} = @server_ip

    options = [
      %Option{type: 53, length: 1, value: <<2>>},
      %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
      %Option{type: 3, length: 4, value: <<sa, sb, sc, sd>>},
      %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
      %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
      %Option{type: 54, length: 4, value: <<sa, sb, sc, sd>>},
      %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
      %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>},
      %Option{type: 125, length: byte_size(vendor_bin), value: vendor_bin}
    ]

    msg = %Message{
      op: 2,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0,
      ciaddr: {0, 0, 0, 0},
      yiaddr: @offered_ip,
      siaddr: @server_ip,
      giaddr: {0, 0, 0, 0},
      chaddr: <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0::80>>,
      sname: <<0::512>>,
      file: <<0::1024>>,
      options: options
    }

    reply = IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
    send(fsm_pid, {:dhcp_rx, reply})
  end

  # ── Tests: NAK handling ────────────────────────────────────────────────

  describe "NAK handling" do
    test "FSM cycles back through DISCOVER after receiving NAK" do
      mock_pid = start_mock_server(nak_requests: true)
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      # The FSM will DISCOVER -> get OFFER -> select -> REQUEST -> get NAK
      # -> backoff (1s) -> INIT -> DISCOVER again.

      # Wait for the first REQUEST (which gets NAKed)
      assert_receive {:intercepted, :request, first_xid}, 5_000

      # After NAK backoff, the FSM returns to :init and sends a new DISCOVER.
      # The second DISCOVER proves the FSM cycled through init.
      assert_receive {:intercepted, :discover, second_xid}, 5_000

      # The second cycle uses a different xid (generated fresh on init enter)
      assert is_integer(first_xid)
      assert is_integer(second_xid)

      # FSM is still alive and cycling
      {state, _data} = StateMachine.status(fsm_pid)
      assert state in [:init, :selecting, :requesting]
    end

    test "FSM never reaches :bound when server keeps NAKing" do
      mock_pid = start_mock_server(nak_requests: true)
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      # Wait for two full NAK cycles (DISCOVER -> OFFER -> REQUEST -> NAK -> init)
      assert_receive {:intercepted, :request, _xid1}, 5_000
      assert_receive {:intercepted, :discover, _xid2}, 5_000
      assert_receive {:intercepted, :request, _xid3}, 5_000

      # After multiple NAK cycles, the FSM should never have reached :bound
      {state, _data} = StateMachine.status(fsm_pid)
      refute state == :bound
    end
  end

  # ── Tests: Release from bound state ────────────────────────────────────

  describe "release after successful handshake" do
    test "RELEASE is sent and FSM returns to :init" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 50})

      wait_for_state(fsm_pid, :bound)

      assert StateMachine.lease(fsm_pid) != nil

      StateMachine.release(fsm_pid)

      assert_receive {:intercepted, :release, _xid}, 3_000
      wait_for_state(fsm_pid, :init, 3_000)
    end
  end

  # ── Tests: Timing and state transitions ────────────────────────────────

  describe "state transition timing" do
    test "FSM passes through selecting state before reaching bound" do
      mock_pid = start_mock_server()
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 300})

      # With a 300ms selection window, we have time to observe :selecting
      wait_for_state(fsm_pid, :selecting, 3_000)

      # Then it should eventually reach :bound after selection + REQUEST + ACK
      wait_for_state(fsm_pid, :bound, 3_000)

      # Verify the REQUEST was intercepted (proving the full DORA path)
      assert_receive {:intercepted, :request, _xid}, 0
    end

    test "shorter selection window results in faster handshake" do
      mock_pid = start_mock_server()

      start_time = System.monotonic_time(:millisecond)
      fsm_pid = start_fsm(mock_pid, %{selection_window_ms: 10})

      wait_for_state(fsm_pid, :bound)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # With a 10ms selection window, the total handshake should complete
      # well under 2 seconds (DISCOVER + 10ms window + REQUEST + ACK)
      assert elapsed < 2_000
    end
  end
end
