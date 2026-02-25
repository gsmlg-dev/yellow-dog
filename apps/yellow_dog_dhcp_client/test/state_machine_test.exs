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

    packet =
      build_reply(
        yiaddr: yiaddr,
        siaddr: server_ip,
        options: offer_options(server_ip) ++ extra_options
      )

    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp send_ack(fsm_pid, opts \\ []) do
    server_ip = Keyword.get(opts, :server_ip, {192, 168, 1, 1})
    yiaddr = Keyword.get(opts, :yiaddr, {192, 168, 1, 100})

    packet =
      build_reply(
        yiaddr: yiaddr,
        siaddr: server_ip,
        options: ack_options(server_ip)
      )

    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp send_nak(fsm_pid) do
    packet = build_reply(options: nak_options())
    send(fsm_pid, {:dhcp_rx, packet})
  end

  defp get_state(pid) do
    {state, _data} = StateMachine.status(pid)
    state
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
end
