defmodule YellowDog.DhcpClient.StateMachineTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.StateMachine
  alias DHCPv4.Message
  alias DHCPv4.Message.Option

  @test_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

  # ── Mock packet module ──

  # Instead of hitting the real network, we configure a mock packet module
  # that records calls and returns deterministic data. The state machine
  # reads the packet module from application env.

  defmodule MockPacket do
    @moduledoc false

    # This module implements the same API as YellowDog.DhcpClient.Packet
    # but does not touch the network. build_* return empty binaries (the
    # mock socket won't actually send them). parse_reply delegates to the
    # real parser so we can inject well-formed replies.

    def build_discover(_mac, _xid, _opts \\ []), do: <<>>
    def build_request(_mac, _xid, _server_ip, _offered_ip, _opts \\ []), do: <<>>
    def build_decline(_mac, _xid, _server_ip, _declined_ip), do: <<>>
    def build_release(_mac, _xid, _server_ip, _client_ip), do: <<>>

    def parse_reply(data) do
      YellowDog.DhcpClient.Packet.parse_reply(data)
    end
  end

  # ── Mock socket ──

  defmodule MockSocketImpl do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.DhcpSocket

    @impl true
    def open(_interface, _owner) do
      {:ok, make_ref()}
    end

    @impl true
    def send_broadcast(_ref, _packet), do: :ok

    @impl true
    def send_unicast(_ref, _dest, _packet), do: :ok

    @impl true
    def send_arp_probe(_ref, _ip), do: {:error, :not_supported}

    @impl true
    def close(_ref), do: :ok
  end

  # ── Setup ──

  setup do
    # Configure mock packet module for the state machine
    prev = Application.get_env(:yellow_dog_dhcp_client, :packet_module)
    Application.put_env(:yellow_dog_dhcp_client, :packet_module, MockPacket)

    on_exit(fn ->
      if prev do
        Application.put_env(:yellow_dog_dhcp_client, :packet_module, prev)
      else
        Application.delete_env(:yellow_dog_dhcp_client, :packet_module)
      end
    end)

    # Start a mock socket process
    {:ok, socket_pid} =
      YellowDog.DhcpClient.DhcpSocket.start_link(
        interface: "test0",
        owner: self(),
        impl: MockSocketImpl
      )

    %{socket_pid: socket_pid}
  end

  defp start_fsm(ctx, config_overrides \\ %{}) do
    config =
      Map.merge(
        %{
          dad_enabled: false,
          selection_window_ms: 50
        },
        config_overrides
      )

    opts = [
      interface: "test0",
      mac: @test_mac,
      socket_pid: ctx.socket_pid,
      config: config
    ]

    opts =
      opts
      |> maybe_add_opt(:store_pid, ctx[:store_pid])
      |> maybe_add_opt(:os_module, ctx[:os_module])

    {:ok, pid} = StateMachine.start_link(opts)
    pid
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_reply(opts) do
    yiaddr = Keyword.get(opts, :yiaddr, {192, 168, 1, 100})
    siaddr = Keyword.get(opts, :siaddr, {192, 168, 1, 1})
    xid = Keyword.get(opts, :xid, 1)
    options = Keyword.get(opts, :options, [])

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
      chaddr: @test_mac <> <<0::80>>,
      sname: <<0::512>>,
      file: <<0::1024>>,
      options: options
    }

    IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
  end

  defp offer_options(server_ip) do
    {a, b, c, d} = server_ip

    [
      %Option{type: 53, length: 1, value: <<2>>},
      %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
      %Option{type: 3, length: 4, value: <<a, b, c, d>>},
      %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
      %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
      %Option{type: 54, length: 4, value: <<a, b, c, d>>},
      %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
      %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>}
    ]
  end

  defp ack_options(server_ip) do
    offer_options(server_ip)
    |> Enum.map(fn
      %Option{type: 53} -> %Option{type: 53, length: 1, value: <<5>>}
      other -> other
    end)
  end

  defp nak_options do
    [%Option{type: 53, length: 1, value: <<6>>}]
  end

  defp send_offer(fsm_pid, opts \\ []) do
    server_ip = Keyword.get(opts, :server_ip, {192, 168, 1, 1})
    yiaddr = Keyword.get(opts, :yiaddr, {192, 168, 1, 100})
    extra_options = Keyword.get(opts, :extra_options, [])
    xid = Keyword.get(opts, :xid, get_xid(fsm_pid))

    packet =
      build_reply(
        xid: xid,
        yiaddr: yiaddr,
        siaddr: server_ip,
        options: offer_options(server_ip) ++ extra_options
      )

    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp send_ack(fsm_pid, opts \\ []) do
    server_ip = Keyword.get(opts, :server_ip, {192, 168, 1, 1})
    yiaddr = Keyword.get(opts, :yiaddr, {192, 168, 1, 100})
    xid = Keyword.get(opts, :xid, get_xid(fsm_pid))

    packet =
      build_reply(
        xid: xid,
        yiaddr: yiaddr,
        siaddr: server_ip,
        options: ack_options(server_ip)
      )

    send(fsm_pid, {:dhcp_rx, packet})
  end

  # Like send_ack but with explicit T1/T2 values (in seconds) for timer tests.
  defp send_ack_with_timers(fsm_pid, t1_s, t2_s) do
    xid = get_xid(fsm_pid)
    {a, b, c, d} = {192, 168, 1, 1}

    options = [
      %Option{type: 53, length: 1, value: <<5>>},
      %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
      %Option{type: 3, length: 4, value: <<a, b, c, d>>},
      %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
      %Option{type: 51, length: 4, value: <<3600::32>>},
      %Option{type: 54, length: 4, value: <<a, b, c, d>>},
      %Option{type: 58, length: 4, value: <<t1_s::32>>},
      %Option{type: 59, length: 4, value: <<t2_s::32>>}
    ]

    packet = build_reply(xid: xid, options: options)
    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp send_nak(fsm_pid, opts \\ []) do
    xid = Keyword.get(opts, :xid, get_xid(fsm_pid))
    packet = build_reply(xid: xid, options: nak_options())
    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp get_state(pid) do
    {state, _data} = StateMachine.status(pid)
    state
  end

  defp get_xid(pid) do
    {_state, data} = StateMachine.status(pid)
    data.xid
  end

  defp wait_for_state(pid, expected_state, timeout \\ 2000) do
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

  # ── Tests ──

  test "starts in :init state", ctx do
    pid = start_fsm(ctx)
    assert get_state(pid) == :init
  end

  test "transitions to :selecting on offer", ctx do
    pid = start_fsm(ctx)
    assert get_state(pid) == :init

    send_offer(pid)

    wait_for_state(pid, :selecting)
  end

  test "transitions to :requesting after selection timeout", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 50})
    assert get_state(pid) == :init

    send_offer(pid)
    wait_for_state(pid, :selecting)

    # Wait for the selection window to expire (50ms + margin)
    wait_for_state(pid, :requesting, 1000)
  end

  test "transitions to :bound on ack", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 50})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)

    send_ack(pid)
    wait_for_state(pid, :bound)
  end

  test "transitions to :init on nak", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 50})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)

    send_nak(pid)

    # NAK causes a backoff, then transitions back to :init
    wait_for_state(pid, :init, 3000)
  end

  test "full DORA cycle reaches :bound", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    # DISCOVER already sent on enter

    # OFFER arrives
    send_offer(pid)
    wait_for_state(pid, :selecting)

    # Selection window expires -> REQUESTING
    wait_for_state(pid, :requesting, 1000)

    # ACK arrives
    send_ack(pid)
    wait_for_state(pid, :bound)

    # Verify lease is populated
    lease = StateMachine.lease(pid)
    assert lease != nil
    assert lease.ip == {192, 168, 1, 100}
    assert lease.server_ip == {192, 168, 1, 1}
  end

  test "release from :bound returns to :init", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    wait_for_state(pid, :bound)

    StateMachine.release(pid)
    wait_for_state(pid, :init, 2000)

    assert StateMachine.lease(pid) == nil
  end

  test "interface_down from :bound returns to :init", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    wait_for_state(pid, :bound)

    send(pid, :interface_down)
    wait_for_state(pid, :init, 2000)

    assert StateMachine.lease(pid) == nil
  end

  test "interface_down from :renewing returns to :init and clears lease", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    wait_for_state(pid, :bound)

    :sys.replace_state(pid, fn {_state, data} -> {:renewing, data} end)
    wait_for_state(pid, :renewing, 500)

    send(pid, :interface_down)
    wait_for_state(pid, :init, 2000)

    assert StateMachine.lease(pid) == nil
  end

  test "interface_down from :rebinding returns to :init and clears lease", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    wait_for_state(pid, :bound)

    :sys.replace_state(pid, fn {_state, data} -> {:rebinding, data} end)
    wait_for_state(pid, :rebinding, 500)

    send(pid, :interface_down)
    wait_for_state(pid, :init, 2000)

    assert StateMachine.lease(pid) == nil
  end

  test "interface_down from :selecting returns to :init", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 500})

    # Send an offer to get into selecting state
    send_offer(pid)
    wait_for_state(pid, :selecting, 500)

    send(pid, :interface_down)
    wait_for_state(pid, :init, 2000)
  end

  test "interface_down from :requesting returns to :init", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)

    send(pid, :interface_down)
    wait_for_state(pid, :init, 2000)
  end

  test "interface_down from :init is a no-op (FSM stays in :init)", ctx do
    pid = start_fsm(ctx)
    assert get_state(pid) == :init

    send(pid, :interface_down)
    Process.sleep(50)

    assert get_state(pid) == :init
  end

  test "status/1 returns state and data", ctx do
    pid = start_fsm(ctx)
    {state, data} = StateMachine.status(pid)

    assert state == :init
    assert data.interface == "test0"
    assert data.mac == @test_mac
  end

  test "lease/1 returns nil before binding", ctx do
    pid = start_fsm(ctx)
    assert StateMachine.lease(pid) == nil
  end

  # ── select_best_offer/1 ──

  describe "select_best_offer/1" do
    test "returns only offer when list has one element" do
      offer = %{ip: {192, 168, 1, 100}, yellowdog_server: false}
      assert StateMachine.select_best_offer([offer]) == offer
    end

    test "prefers yellowdog_server offer" do
      regular = %{ip: {192, 168, 1, 100}, yellowdog_server: false}
      yellowdog = %{ip: {192, 168, 1, 200}, yellowdog_server: true}

      # Offers are in reverse order (most recent first), so put yellowdog last
      result = StateMachine.select_best_offer([yellowdog, regular])
      assert result.ip == {192, 168, 1, 200}
    end

    test "prefers yellowdog_server even when received last" do
      regular = %{ip: {192, 168, 1, 100}, yellowdog_server: false}
      yellowdog = %{ip: {192, 168, 1, 200}, yellowdog_server: true}

      # yellowdog received first (at end of reversed list)
      result = StateMachine.select_best_offer([regular, yellowdog])
      assert result.ip == {192, 168, 1, 200}
    end

    test "prefers yellowdog_vendor_class over known_server (tier 2 vs tier 3)" do
      regular = %{
        ip: {192, 168, 1, 100},
        yellowdog_server: false,
        yellowdog_vendor_class: false,
        known_server: true
      }

      vendor_class = %{
        ip: {192, 168, 1, 200},
        yellowdog_server: false,
        yellowdog_vendor_class: true,
        known_server: false
      }

      result = StateMachine.select_best_offer([regular, vendor_class])
      assert result.ip == {192, 168, 1, 200}
    end

    test "yellowdog_server (tier 1) beats yellowdog_vendor_class (tier 2)" do
      pen_match = %{
        ip: {192, 168, 1, 100},
        yellowdog_server: true,
        yellowdog_vendor_class: true
      }

      class_only = %{
        ip: {192, 168, 1, 200},
        yellowdog_server: false,
        yellowdog_vendor_class: true
      }

      result = StateMachine.select_best_offer([class_only, pen_match])
      assert result.ip == {192, 168, 1, 100}
    end

    test "falls back to known_server when no yellowdog" do
      regular = %{ip: {192, 168, 1, 100}, yellowdog_server: false, known_server: false}
      known = %{ip: {192, 168, 1, 150}, yellowdog_server: false, known_server: true}

      result = StateMachine.select_best_offer([known, regular])
      assert result.ip == {192, 168, 1, 150}
    end

    test "falls back to FIFO when no yellowdog or known_server" do
      first = %{ip: {192, 168, 1, 100}, yellowdog_server: false}
      second = %{ip: {192, 168, 1, 200}, yellowdog_server: false}

      # Offers are stored in reverse order; reversed = chronological
      # [second, first] reversed => [first, second]; List.first => first
      result = StateMachine.select_best_offer([second, first])
      assert result.ip == {192, 168, 1, 100}
    end

    test "handles offers without yellowdog_server key" do
      offer1 = %{ip: {192, 168, 1, 100}}
      offer2 = %{ip: {192, 168, 1, 200}}

      result = StateMachine.select_best_offer([offer2, offer1])
      assert result != nil
    end

    test "returns nil for empty list" do
      assert StateMachine.select_best_offer([]) == nil
    end
  end

  # ── multiple offers in selecting state ──

  test "accumulates multiple offers in selecting state", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 200})

    send_offer(pid, yiaddr: {192, 168, 1, 100})
    wait_for_state(pid, :selecting)

    send_offer(pid, yiaddr: {192, 168, 1, 200}, server_ip: {192, 168, 2, 1})

    # Both offers should be accumulated
    {_state, data} = StateMachine.status(pid)
    assert length(data.offers) == 2
  end

  test "returns to :init when selection window expires with no offers", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 200})

    send_offer(pid)
    wait_for_state(pid, :selecting)

    # Clear the accumulated offers so the selection fires with an empty list
    :sys.replace_state(pid, fn {state, data} ->
      if state == :selecting, do: {state, %{data | offers: []}}, else: {state, data}
    end)

    # Selection window fires: select_best_offer([]) -> nil -> back to :init
    wait_for_state(pid, :init, 1000)
  end

  test "ignores non-offer packets in init state", ctx do
    pid = start_fsm(ctx)

    # Send an ACK while in init - should be ignored
    send_ack(pid)
    Process.sleep(50)

    assert get_state(pid) == :init
  end

  test "ignores non-offer packets in selecting state", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 500})

    send_offer(pid)
    wait_for_state(pid, :selecting)

    # Send ACK while selecting - should be ignored (only offers are collected)
    send_ack(pid)
    Process.sleep(50)

    assert get_state(pid) == :selecting
  end

  test "garbage binary {:dhcp_rx} does not crash the FSM", ctx do
    pid = start_fsm(ctx, %{selection_window_ms: 500})

    # Inject malformed binary data — parse_reply will return {:error, _}
    # and the FSM should stay alive in :init
    send(pid, {:dhcp_rx, <<0xFF, 0xFE, 0xFD>>})
    send(pid, {:dhcp_rx, <<>>})
    Process.sleep(50)

    assert Process.alive?(pid)
    assert get_state(pid) == :init
  end

  test "dad_probes: 0 skips all ARP probes and still reaches :bound", ctx do
    pid =
      start_fsm(ctx, %{
        selection_window_ms: 30,
        dad_enabled: true,
        dad_probes: 0,
        dad_wait_ms: 200,
        dad_backoff_ms: 100
      })

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    # With zero probes, DAD loop is skipped; await_conflict waits dad_wait_ms then :ok
    wait_for_state(pid, :bound, 2000)
  end

  test "DAD conflict causes DECLINE and returns to :init after backoff", ctx do
    pid =
      start_fsm(ctx, %{
        selection_window_ms: 30,
        dad_enabled: true,
        dad_probes: 1,
        dad_wait_ms: 2000,
        dad_backoff_ms: 100
      })

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)

    # Send ACK — triggers DAD.check in the FSM process (blocks in await_conflict)
    send_ack(pid)

    # Give the FSM a moment to enter DAD.check's await_conflict receive loop
    Process.sleep(50)

    # Inject ARP conflict reply targeting the offered IP
    send(pid, {:arp_rx, {192, 168, 1, 100}, <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>})

    # FSM sends DECLINE, schedules dad_backoff (100ms), then transitions to :init
    wait_for_state(pid, :init, 2000)
  end

  test "emits state:change telemetry with non-negative duration_in_state_ms", ctx do
    ref = make_ref()
    self_pid = self()

    :telemetry.attach(
      "test-state-change-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :state, :change],
      fn _event, measurements, metadata, _config ->
        send(self_pid, {:state_change, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-state-change-#{inspect(ref)}") end)

    pid = start_fsm(ctx, %{selection_window_ms: 30})

    send_offer(pid)
    wait_for_state(pid, :requesting, 1000)
    send_ack(pid)
    wait_for_state(pid, :bound)

    # Collect all state:change events
    events =
      Enum.reduce_while(1..10, [], fn _, acc ->
        receive do
          {:state_change, meas, meta} -> {:cont, [{meas, meta} | acc]}
        after
          100 -> {:halt, acc}
        end
      end)

    assert length(events) >= 3,
           "Expected at least 3 state changes (init, selecting, requesting, bound)"

    for {meas, meta} <- events do
      assert is_integer(meas.duration_in_state_ms)
      assert meas.duration_in_state_ms >= 0
      assert Map.has_key?(meta, :from)
      assert Map.has_key?(meta, :to)
    end
  end

  # ── LeaseStore integration ──

  describe "lease store integration" do
    setup ctx do
      lease_dir =
        Path.join(System.tmp_dir!(), "yd_fsm_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(lease_dir)
      on_exit(fn -> File.rm_rf!(lease_dir) end)

      {:ok, store_pid} =
        YellowDog.DhcpClient.LeaseStore.start_link(
          interface: "test0",
          lease_dir: lease_dir
        )

      Map.merge(ctx, %{store_pid: store_pid, lease_dir: lease_dir})
    end

    test "persists lease to store on bound", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Lease should be persisted in the store
      assert {:ok, lease} = YellowDog.DhcpClient.LeaseStore.lookup(ctx.store_pid, "test0")
      assert lease.ip == {192, 168, 1, 100}
    end

    test "deletes lease from store on release", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Lease is in the store
      assert {:ok, _} = YellowDog.DhcpClient.LeaseStore.lookup(ctx.store_pid, "test0")

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      # After release, lease should be deleted from store
      assert :not_found = YellowDog.DhcpClient.LeaseStore.lookup(ctx.store_pid, "test0")
    end

    test "starts in :rebinding when store has a valid persisted lease", ctx do
      # Pre-populate the store with a valid non-expired lease
      valid_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 50},
        subnet_mask: {255, 255, 255, 0},
        server_ip: {192, 168, 1, 1},
        router: {192, 168, 1, 1},
        dns_servers: [],
        ntp_servers: [],
        lease_time: 3600,
        t1: 1800,
        t2: 3150,
        obtained_at: DateTime.utc_now(),
        xid: 0xDEADBEEF,
        yellowdog_server: false,
        vendor_options: %{},
        raw_options: %{}
      }

      YellowDog.DhcpClient.LeaseStore.store(ctx.store_pid, "test0", valid_lease)

      # Start a new FSM that shares the same store — it should recover the lease
      {:ok, pid2} =
        YellowDog.DhcpClient.StateMachine.start_link(
          interface: "test0",
          mac: @test_mac,
          socket_pid: ctx.socket_pid,
          store_pid: ctx.store_pid,
          config: %{dad_enabled: false, selection_window_ms: 50}
        )

      # The FSM should enter :rebinding immediately (skipping DISCOVER)
      wait_for_state(pid2, :rebinding, 1000)

      {_state, data} = StateMachine.status(pid2)
      assert data.lease.ip == {192, 168, 1, 50}
      # xid must be a freshly generated integer — nil xid crashes the real
      # Packet encoder when build_request is called from the :rebinding enter handler
      assert is_integer(data.xid) and data.xid > 0
    end

    test "marks offer as known_server when it matches the stored server_ip", ctx do
      # Use an expired lease so the FSM starts in :init (not :rebinding) but the
      # server_ip is still present in the store for maybe_mark_known_server to match.
      prior_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 50},
        subnet_mask: {255, 255, 255, 0},
        server_ip: {192, 168, 1, 1},
        router: {192, 168, 1, 1},
        dns_servers: [],
        ntp_servers: [],
        lease_time: 1,
        t1: 1,
        t2: 1,
        obtained_at: ~U[2000-01-01 00:00:00Z],
        xid: 0xABCD1234,
        yellowdog_server: false,
        vendor_options: %{},
        raw_options: %{}
      }

      YellowDog.DhcpClient.LeaseStore.store(ctx.store_pid, "test0", prior_lease)

      pid = start_fsm(ctx, %{selection_window_ms: 200})

      send_offer(pid, server_ip: {192, 168, 1, 1})
      wait_for_state(pid, :selecting)

      {_state, data} = StateMachine.status(pid)
      offer = List.first(data.offers)
      assert offer.known_server == true
    end

    test "does not mark offer as known_server when server_ip differs from stored lease", ctx do
      prior_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 50},
        subnet_mask: {255, 255, 255, 0},
        server_ip: {192, 168, 1, 1},
        router: nil,
        dns_servers: [],
        ntp_servers: [],
        lease_time: 1,
        t1: 1,
        t2: 1,
        obtained_at: ~U[2000-01-01 00:00:00Z],
        xid: 0xABCD1234,
        yellowdog_server: false,
        vendor_options: %{},
        raw_options: %{}
      }

      YellowDog.DhcpClient.LeaseStore.store(ctx.store_pid, "test0", prior_lease)

      pid = start_fsm(ctx, %{selection_window_ms: 200})

      # Different server than the stored lease
      send_offer(pid, server_ip: {10, 0, 0, 1})
      wait_for_state(pid, :selecting)

      {_state, data} = StateMachine.status(pid)
      offer = List.first(data.offers)
      assert offer.known_server == false
    end

    test "starts in :init when store has an expired persisted lease", ctx do
      # Pre-populate the store with an expired lease
      expired_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 50},
        subnet_mask: {255, 255, 255, 0},
        server_ip: {192, 168, 1, 1},
        router: nil,
        dns_servers: [],
        ntp_servers: [],
        lease_time: 1,
        t1: 1,
        t2: 1,
        obtained_at: ~U[2000-01-01 00:00:00Z],
        xid: 0xDEADBEEF,
        yellowdog_server: false,
        vendor_options: %{},
        raw_options: %{}
      }

      YellowDog.DhcpClient.LeaseStore.store(ctx.store_pid, "test0", expired_lease)

      {:ok, pid2} =
        YellowDog.DhcpClient.StateMachine.start_link(
          interface: "test0",
          mac: @test_mac,
          socket_pid: ctx.socket_pid,
          store_pid: ctx.store_pid,
          config: %{dad_enabled: false, selection_window_ms: 50}
        )

      # Expired lease → should start from :init (send DISCOVER)
      assert get_state(pid2) == :init
    end
  end

  # ── OS integration ──

  defmodule MockOSIntegration do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.OSIntegration

    @impl true
    def apply_lease(interface, lease) do
      send(Process.whereis(:os_integration_test), {:apply_lease, interface, lease})
      :ok
    end

    @impl true
    def deconfigure(interface) do
      send(Process.whereis(:os_integration_test), {:deconfigure, interface})
      :ok
    end

    @impl true
    def apply_routes(_interface, _lease), do: :ok

    @impl true
    def apply_dns(_interface, _lease), do: :ok
  end

  defmodule MockOSIntegrationError do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.OSIntegration

    @impl true
    def apply_lease(_interface, _lease), do: {:error, :simulated_os_error}

    @impl true
    def deconfigure(_interface), do: {:error, :simulated_os_error}

    @impl true
    def apply_routes(_interface, _lease), do: :ok

    @impl true
    def apply_dns(_interface, _lease), do: :ok
  end

  defmodule MockOSIntegrationRaise do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.OSIntegration

    @impl true
    def apply_lease(_interface, _lease), do: raise("simulated OS apply_lease crash")

    @impl true
    def deconfigure(_interface), do: raise("simulated OS deconfigure crash")

    @impl true
    def apply_routes(_interface, _lease), do: :ok

    @impl true
    def apply_dns(_interface, _lease), do: :ok
  end

  describe "OS integration" do
    setup ctx do
      Process.register(self(), :os_integration_test)

      on_exit(fn ->
        try do
          Process.unregister(:os_integration_test)
        rescue
          _ -> :ok
        end
      end)

      Map.put(ctx, :os_module, MockOSIntegration)
    end

    test "calls apply_lease on bound", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      assert_receive {:apply_lease, "test0", lease}, 1000
      assert lease.ip == {192, 168, 1, 100}
    end

    test "calls deconfigure on release", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Drain apply_lease message
      assert_receive {:apply_lease, "test0", _}, 1000

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      assert_receive {:deconfigure, "test0"}, 1000
    end

    test "calls deconfigure on interface_down", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Drain apply_lease message
      assert_receive {:apply_lease, "test0", _}, 1000

      send(pid, :interface_down)
      wait_for_state(pid, :init, 2000)

      assert_receive {:deconfigure, "test0"}, 1000
    end
  end

  # ── OS integration resilience ──

  describe "OS integration resilience" do
    test "apply_lease returning {:error, reason} does not prevent FSM reaching :bound", ctx do
      pid =
        start_fsm(Map.put(ctx, :os_module, MockOSIntegrationError), %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound, 2000)

      assert is_struct(StateMachine.lease(pid), YellowDog.DhcpClient.Lease)
    end

    test "apply_lease raising exception does not crash FSM — FSM still reaches :bound", ctx do
      pid =
        start_fsm(Map.put(ctx, :os_module, MockOSIntegrationRaise), %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound, 2000)

      assert is_struct(StateMachine.lease(pid), YellowDog.DhcpClient.Lease)
    end

    test "deconfigure returning {:error, reason} does not prevent return to :init", ctx do
      pid =
        start_fsm(Map.put(ctx, :os_module, MockOSIntegrationError), %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end

    test "deconfigure raising exception does not crash FSM — FSM returns to :init", ctx do
      pid =
        start_fsm(Map.put(ctx, :os_module, MockOSIntegrationRaise), %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end
  end

  # ── Telemetry events ──

  describe "telemetry events" do
    test "emits lease:bound on initial bind", ctx do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-lease-bound-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :lease, :bound],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_bound, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-lease-bound-#{inspect(ref)}") end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      assert_receive {:telemetry_bound, measurements, metadata}, 2000
      assert is_integer(measurements.handshake_duration_ms)
      assert metadata.interface == "test0"
    end

    test "emits lease:renewed on renewal (RENEWING -> BOUND)", ctx do
      ref = make_ref()
      self_pid = self()
      renewed_events = :counters.new(1, [])

      :telemetry.attach(
        "test-lease-renewed-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :lease, :renewed],
        fn _event, measurements, metadata, _config ->
          :counters.add(renewed_events, 1, 1)
          send(self_pid, {:telemetry_renewed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-lease-renewed-#{inspect(ref)}") end)

      # Get to bound first with very short T1
      pid =
        start_fsm(ctx, %{
          selection_window_ms: 30
        })

      send_offer(pid,
        yiaddr: {192, 168, 1, 100},
        server_ip: {192, 168, 1, 1}
      )

      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Manually trigger T1 to enter RENEWING
      send(pid, {:"$gen_cast", {:timeout, :t1, :renew}})
      # The above won't work with gen_statem; instead force via internal
      # We need to wait for T1 or manually transition. T1 is lease_time/2 = 1800s.
      # Instead, let's simulate by directly pushing a renew timeout event.
      # Actually gen_statem timeouts can't be faked externally. Let's use status
      # to get the process and force-transition by injecting the event.

      # More practical: create a short-lease scenario and check the telemetry on
      # renewing->bound. We can't fake the T1 timer easily, so let's test
      # by sending an ACK in the renewing state manually.

      # Move to renewing state by casting a direct state change via a
      # well-formed ACK after we manually send the renew event
      # The simplest way: use :sys.replace_state
      :sys.replace_state(pid, fn {state, data} ->
        if state == :bound do
          {:renewing, data}
        else
          {state, data}
        end
      end)

      # Now in :renewing, send an ACK to trigger RENEWING -> BOUND
      send_ack(pid)
      wait_for_state(pid, :bound, 2000)

      assert_receive {:telemetry_renewed, measurements, metadata}, 2000
      assert is_integer(measurements.lease_time_s)
      assert metadata.interface == "test0"
    end
  end

  # ── Retransmission limits ──

  describe "retransmit limits" do
    test "REQUESTING returns to :init after max retransmit attempts", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)

      # Set retransmit_count to 3 so the next timeout (count=4) hits the limit
      :sys.replace_state(pid, fn {state, data} ->
        if state == :requesting do
          {state, %{data | retransmit_count: 3}}
        else
          {state, data}
        end
      end)

      # The retransmit timer from entering :requesting is already set. Wait for
      # it to fire; since count 4 >= @max_request_attempts (4), FSM → :init
      wait_for_state(pid, :init, 5000)
    end

    test "INIT retransmit regenerates xid", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 50})
      {_, data1} = StateMachine.status(pid)
      xid1 = data1.xid

      # Wait for the first retransmit timeout to fire (2s + jitter)
      Process.sleep(3500)

      {state, data2} = StateMachine.status(pid)
      assert state == :init
      assert data2.xid != xid1, "xid should change after retransmit"
    end
  end

  # ── Rebinding edge cases ──

  describe "rebinding" do
    test "ACK in :rebinding returns to :bound", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      # Get to :bound first
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Force into :rebinding
      :sys.replace_state(pid, fn {_state, data} ->
        {:rebinding, data}
      end)

      wait_for_state(pid, :rebinding, 500)

      # Send ACK → should return to :bound
      send_ack(pid)
      wait_for_state(pid, :bound, 2000)
    end

    test "NAK in :rebinding returns to :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} ->
        {:rebinding, data}
      end)

      wait_for_state(pid, :rebinding, 500)

      send_nak(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end

    test "stray OFFER while :rebinding is silently ignored", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:rebinding, data} end)
      wait_for_state(pid, :rebinding, 500)

      send_offer(pid)
      Process.sleep(100)

      assert get_state(pid) == :rebinding
    end
  end

  # ── Renewing ──

  describe "renewing" do
    test "ACK in :renewing returns to :bound", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      # Force into :renewing
      :sys.replace_state(pid, fn {_state, data} ->
        {:renewing, data}
      end)

      wait_for_state(pid, :renewing, 500)

      send_ack(pid)
      wait_for_state(pid, :bound, 2000)

      assert is_struct(StateMachine.lease(pid), YellowDog.DhcpClient.Lease)
    end

    test "NAK in :renewing returns to :init and clears lease", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} ->
        {:renewing, data}
      end)

      wait_for_state(pid, :renewing, 500)

      send_nak(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end

    test "ACK without Option 58/59 computes RFC defaults: t1=lease_time/2, t2=7*lease_time/8",
         ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)

      # Build ACK with lease_time=3600 but NO Option 58 (t1) or 59 (t2)
      xid = get_xid(pid)
      {a, b, c, d} = {192, 168, 1, 1}

      opts_no_timers = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
        %Option{type: 3, length: 4, value: <<a, b, c, d>>},
        %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
        %Option{type: 51, length: 4, value: <<3600::32>>},
        %Option{type: 54, length: 4, value: <<a, b, c, d>>}
        # No type 58 or 59 — parse_reply fills in RFC defaults
      ]

      send(pid, {:dhcp_rx, build_reply(xid: xid, options: opts_no_timers)})
      wait_for_state(pid, :bound, 2000)

      lease = StateMachine.lease(pid)
      assert lease.lease_time == 3600
      # parse_reply computes: t1 = lease_time / 2 = 1800, t2 = 7 * lease_time / 8 = 3150
      assert lease.t1 == 1800
      assert lease.t2 == 3150
    end

    test "T2 timeout while :renewing transitions to :rebinding", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      # ACK with T1=1s, T2=2s so timers fire quickly
      send_ack_with_timers(pid, 1, 2)
      wait_for_state(pid, :bound)

      # T1 fires after ~1s → :renewing
      wait_for_state(pid, :renewing, 2000)

      # T2 fires after ~2s from :bound entry → :rebinding
      wait_for_state(pid, :rebinding, 3000)

      assert is_struct(StateMachine.lease(pid), YellowDog.DhcpClient.Lease)
    end

    test "stray OFFER while :renewing is silently ignored", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:renewing, data} end)
      wait_for_state(pid, :renewing, 500)

      send_offer(pid)
      Process.sleep(100)

      assert get_state(pid) == :renewing
    end
  end

  # ── Lease expired telemetry ──

  describe "lease expired telemetry" do
    setup ctx do
      Process.register(self(), :os_integration_test)

      on_exit(fn ->
        try do
          Process.unregister(:os_integration_test)
        rescue
          _ -> :ok
        end
      end)

      Map.put(ctx, :os_module, MockOSIntegration)
    end

    test "emits lease:expired telemetry when rebinding lease expires", ctx do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-lease-expired-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :lease, :expired],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:telemetry_expired, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-lease-expired-#{inspect(ref)}") end)

      # Pre-populate the store with a lease that is almost expired (lease_time=2s,
      # obtained 1s ago). When the FSM starts and enters :rebinding via disk
      # recovery, remaining_until_expiry will be ~1s (the minimum), causing the
      # lease_expired timeout to fire quickly.
      lease_dir =
        Path.join(System.tmp_dir!(), "yd_expired_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(lease_dir)
      on_exit(fn -> File.rm_rf!(lease_dir) end)

      {:ok, store_pid} =
        YellowDog.DhcpClient.LeaseStore.start_link(
          interface: "test0",
          lease_dir: lease_dir
        )

      almost_expired_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 50},
        subnet_mask: {255, 255, 255, 0},
        server_ip: {192, 168, 1, 1},
        router: {192, 168, 1, 1},
        dns_servers: [],
        ntp_servers: [],
        lease_time: 2,
        t1: 1,
        t2: 1,
        obtained_at: DateTime.add(DateTime.utc_now(), -1, :second),
        xid: 0xDEADBEEF,
        yellowdog_server: false,
        vendor_options: %{},
        raw_options: %{}
      }

      YellowDog.DhcpClient.LeaseStore.store(store_pid, "test0", almost_expired_lease)

      # Start FSM with the store — it should enter :rebinding and then
      # the lease_expired timeout should fire within ~1-2s
      {:ok, pid} =
        StateMachine.start_link(
          interface: "test0",
          mac: @test_mac,
          socket_pid: ctx.socket_pid,
          store_pid: store_pid,
          os_module: MockOSIntegration,
          config: %{dad_enabled: false, selection_window_ms: 50}
        )

      wait_for_state(pid, :rebinding, 1000)

      # Wait for lease_expired timeout to fire (min 1s in remaining_until_expiry)
      wait_for_state(pid, :init, 3000)

      assert_receive {:telemetry_expired, %{interface: "test0"}}, 2000
      assert_receive {:deconfigure, "test0"}, 1000
    end
  end

  # ── Release from non-bound states ──

  describe "release from non-bound states" do
    test "release from :init is a no-op", ctx do
      pid = start_fsm(ctx)
      assert get_state(pid) == :init

      StateMachine.release(pid)
      Process.sleep(50)
      assert get_state(pid) == :init
    end

    test "release from :selecting returns to :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 500})

      send_offer(pid)
      wait_for_state(pid, :selecting)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)
    end

    test "release from :requesting returns to :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)
    end

    test "release from :renewing sends RELEASE and returns to :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:renewing, data} end)
      wait_for_state(pid, :renewing, 500)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end

    test "release from :rebinding sends RELEASE and returns to :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:rebinding, data} end)
      wait_for_state(pid, :rebinding, 500)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 2000)

      assert StateMachine.lease(pid) == nil
    end
  end

  describe "xid filtering" do
    test "ignores offer with mismatched xid", ctx do
      pid = start_fsm(ctx)
      wait_for_state(pid, :init)

      # Send an offer with a wrong xid — should be silently dropped
      send_offer(pid, xid: 0xDEADBEEF)
      Process.sleep(100)

      assert get_state(pid) == :init
    end

    test "ignores ACK with mismatched xid in :requesting", ctx do
      pid = start_fsm(ctx)
      wait_for_state(pid, :init)

      send_offer(pid)
      wait_for_state(pid, :selecting)
      wait_for_state(pid, :requesting, 1000)

      # Send ACK with wrong xid
      send_ack(pid, xid: 0xDEADBEEF)
      Process.sleep(100)

      # Should still be in requesting (not bound)
      assert get_state(pid) == :requesting
    end

    test "ignores ACK with mismatched xid in :renewing", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:renewing, data} end)
      wait_for_state(pid, :renewing, 500)

      send_ack(pid, xid: 0xDEADBEEF)
      Process.sleep(100)

      assert get_state(pid) == :renewing
    end

    test "ignores ACK with mismatched xid in :rebinding", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      :sys.replace_state(pid, fn {_state, data} -> {:rebinding, data} end)
      wait_for_state(pid, :rebinding, 500)

      send_ack(pid, xid: 0xDEADBEEF)
      Process.sleep(100)

      assert get_state(pid) == :rebinding
    end
  end

  # ── Packet telemetry ──

  describe "packet telemetry" do
    defp attach_packet_telemetry(ref, self_pid) do
      :telemetry.attach(
        "test-packet-tx-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :packet, :tx],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:packet_tx, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-packet-rx-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :packet, :rx],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:packet_rx, metadata})
        end,
        nil
      )
    end

    test "emits packet:tx :discover on init entry", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      _pid = start_fsm(ctx, %{selection_window_ms: 30})

      assert_receive {:packet_tx, %{type: :discover, interface: "test0"}}, 500
    end

    test "emits packet:tx :request on requesting entry", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)

      assert_receive {:packet_tx, %{type: :request, interface: "test0"}}, 500
    end

    test "emits packet:tx :release on release", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      StateMachine.release(pid)
      wait_for_state(pid, :init, 1000)

      assert_receive {:packet_tx, %{type: :release, interface: "test0"}}, 500
    end

    test "emits packet:rx :offer when offer received", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid, server_ip: {192, 168, 1, 1})

      assert_receive {:packet_rx, %{type: :offer, interface: "test0", server: server}}, 500
      assert server == "192.168.1.1"
    end

    test "emits packet:rx :ack when ACK received", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid, server_ip: {192, 168, 1, 1})

      assert_receive {:packet_rx, %{type: :ack, interface: "test0", server: server}}, 500
      assert server == "192.168.1.1"
    end

    test "emits packet:rx :nak when NAK received", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_nak(pid)

      assert_receive {:packet_rx, %{type: :nak, interface: "test0"}}, 500
    end

    test "emits packet:rx :nak with server: \"unknown\" when NAK has no server_ip", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_nak(pid)

      assert_receive {:packet_rx, %{type: :nak, server: server}}, 500
      # NAK carries no lease, so emit_packet_rx passes nil → "unknown"
      assert server == "unknown"
    end

    test "emits packet:tx :decline on DAD conflict", ctx do
      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      pid =
        start_fsm(ctx, %{
          selection_window_ms: 30,
          dad_enabled: true,
          dad_probes: 1,
          dad_wait_ms: 2000,
          dad_backoff_ms: 100
        })

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)

      # Give FSM time to enter DAD.check's await_conflict receive loop
      Process.sleep(50)

      # Inject ARP conflict — FSM sends DECLINE and emits packet:tx :decline
      send(pid, {:arp_rx, {192, 168, 1, 100}, <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>})

      assert_receive {:packet_tx, %{type: :decline, interface: "test0"}}, 2000
    end
  end

  # ── Packets in :bound (should be silently ignored) ──

  describe "stray packets in :bound" do
    test "ACK received while :bound is silently ignored — stays :bound with original lease",
         ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      original_lease = StateMachine.lease(pid)
      assert original_lease != nil

      # Send another ACK offering a different IP while in :bound
      send_ack(pid, yiaddr: {10, 20, 30, 40})
      Process.sleep(100)

      assert get_state(pid) == :bound
      assert StateMachine.lease(pid).ip == original_lease.ip
    end

    test "OFFER received while :bound is silently ignored — stays :bound", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})

      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      send_offer(pid)
      Process.sleep(100)

      assert get_state(pid) == :bound
    end
  end

  # ── XID filtering in :init ──

  describe "XID filtering in :init" do
    test "OFFER with wrong XID while :init is discarded — FSM stays in :init", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 500})
      assert get_state(pid) == :init

      send_offer(pid, xid: 0xBADBAD00)
      Process.sleep(50)

      assert get_state(pid) == :init
    end

    test "OFFER with correct XID while :init transitions to :selecting", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 500})
      assert get_state(pid) == :init

      send_offer(pid)
      wait_for_state(pid, :selecting, 500)
    end
  end

  # ── Store crash fallback ──

  describe "store crash fallback" do
    test "starts in :init when store_pid raises on lookup (try_recover_from_store rescues)",
         ctx do
      # Passing a bad store_pid causes LeaseStore.lookup to raise (exit).
      # try_recover_from_store rescues and returns :not_found → FSM starts in :init.
      {:ok, pid} =
        StateMachine.start_link(
          interface: "test0",
          mac: @test_mac,
          socket_pid: ctx.socket_pid,
          store_pid: :nonexistent_store_atom,
          config: %{dad_enabled: false, selection_window_ms: 50}
        )

      assert get_state(pid) == :init
    end
  end

  # ── XID filtering in :selecting ──

  describe "XID filtering in :selecting" do
    test "offer with correct XID is accumulated; offer with wrong XID is not", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 500})

      # Send one valid offer (correct XID) to enter :selecting
      send_offer(pid)
      wait_for_state(pid, :selecting)

      {_state, data_before} = StateMachine.status(pid)
      count_before = length(data_before.offers)

      # Send an offer with the wrong XID — should be discarded silently
      send_offer(pid, xid: 0xBADBAD00)
      Process.sleep(50)

      {_state, data_after} = StateMachine.status(pid)
      assert length(data_after.offers) == count_before
    end
  end

  # ── terminate/3 cleanup ──

  describe "terminate/3 cleanup" do
    test "terminating while :bound sends DHCPRELEASE via packet:tx telemetry", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})
      send_offer(pid)
      wait_for_state(pid, :requesting, 1000)
      send_ack(pid)
      wait_for_state(pid, :bound)

      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      :gen_statem.stop(pid)

      assert_receive {:packet_tx, %{type: :release, interface: "test0"}}, 500
    end

    test "terminating while :init does NOT send DHCPRELEASE", ctx do
      pid = start_fsm(ctx, %{selection_window_ms: 30})
      assert get_state(pid) == :init

      ref = make_ref()
      attach_packet_telemetry(ref, self())

      on_exit(fn ->
        :telemetry.detach("test-packet-tx-#{inspect(ref)}")
        :telemetry.detach("test-packet-rx-#{inspect(ref)}")
      end)

      :gen_statem.stop(pid)

      refute_receive {:packet_tx, %{type: :release}}, 200
    end
  end
end
