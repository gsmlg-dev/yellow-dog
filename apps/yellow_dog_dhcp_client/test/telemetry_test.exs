defmodule YellowDog.DhcpClient.TelemetryTest.MockDadSocket do
  @behaviour YellowDog.DhcpClient.DhcpSocket
  @impl true
  def open(_interface, _owner), do: {:ok, make_ref()}
  @impl true
  def send_broadcast(_ref, _packet), do: :ok
  @impl true
  def send_unicast(_ref, _dest, _packet), do: :ok
  @impl true
  def send_arp_probe(_ref, _ip), do: :ok
  @impl true
  def close(_ref), do: :ok
end

defmodule YellowDog.DhcpClient.TelemetryTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.Telemetry

  # Each test attaches a unique handler to avoid cross-test interference.

  defp attach(event_name) do
    ref = make_ref()
    test_pid = self()
    handler_id = "telemetry-test-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  # -- state_change/4 --

  describe "state_change/4" do
    test "emits [:yellow_dog, :dhcp_client, :state, :change] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :state, :change])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.state_change("eth0", :init, :selecting, 150)

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :state, :change],
                      %{duration_in_state_ms: 150},
                      %{interface: "eth0", from: :init, to: :selecting}}
    end

    test "includes correct from/to states and duration" do
      handler_id = attach([:yellow_dog, :dhcp_client, :state, :change])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.state_change("wlan0", :bound, :renewing, 1800_000)

      assert_receive {:telemetry, _, %{duration_in_state_ms: 1_800_000},
                      %{interface: "wlan0", from: :bound, to: :renewing}}
    end
  end

  # -- packet_tx/2 --

  describe "packet_tx/2" do
    test "emits [:yellow_dog, :dhcp_client, :packet, :tx] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :packet, :tx])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.packet_tx("eth0", :discover)

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :packet, :tx], %{},
                      %{interface: "eth0", type: :discover}}
    end

    test "includes request type in metadata" do
      handler_id = attach([:yellow_dog, :dhcp_client, :packet, :tx])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.packet_tx("wlan0", :request)

      assert_receive {:telemetry, _, _, %{interface: "wlan0", type: :request}}
    end
  end

  # -- packet_rx/3 --

  describe "packet_rx/3" do
    test "emits [:yellow_dog, :dhcp_client, :packet, :rx] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :packet, :rx])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.packet_rx("eth0", :offer, {192, 168, 1, 1})

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :packet, :rx], %{},
                      %{interface: "eth0", type: :offer, server: {192, 168, 1, 1}}}
    end
  end

  # -- lease_bound/5 --

  describe "lease_bound/5" do
    test "emits [:yellow_dog, :dhcp_client, :lease, :bound] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :lease, :bound])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.lease_bound("eth0", "192.168.1.100", "192.168.1.1", 3600, 250)

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :lease, :bound],
                      %{lease_time_s: 3600, handshake_duration_ms: 250},
                      %{interface: "eth0", ip: "192.168.1.100", server: "192.168.1.1"}}
    end

    test "measurements contain lease_time_s and handshake_duration_ms" do
      handler_id = attach([:yellow_dog, :dhcp_client, :lease, :bound])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.lease_bound("wlan0", "10.0.0.5", "10.0.0.1", 86_400, 500)

      assert_receive {:telemetry, _, measurements, _}
      assert measurements.lease_time_s == 86_400
      assert measurements.handshake_duration_ms == 500
    end
  end

  # -- lease_renewed/3 --

  describe "lease_renewed/3" do
    test "emits [:yellow_dog, :dhcp_client, :lease, :renewed] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :lease, :renewed])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.lease_renewed("eth0", "192.168.1.100", 7200)

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :lease, :renewed],
                      %{lease_time_s: 7200}, %{interface: "eth0", ip: "192.168.1.100"}}
    end
  end

  # -- lease_expired/2 --

  describe "lease_expired/2" do
    test "emits [:yellow_dog, :dhcp_client, :lease, :expired] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :lease, :expired])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.lease_expired("eth0", "192.168.1.100")

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :lease, :expired], %{},
                      %{interface: "eth0", ip: "192.168.1.100"}}
    end
  end

  # -- os_apply/4 --

  describe "os_apply/4" do
    test "emits [:yellow_dog, :dhcp_client, :os, :apply] event" do
      handler_id = attach([:yellow_dog, :dhcp_client, :os, :apply])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.os_apply("eth0", :add_ip, :ok, 45)

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :os, :apply], %{duration_ms: 45},
                      %{interface: "eth0", action: :add_ip, result: :ok}}
    end
  end

  # -- DAD telemetry (emitted by DAD.check/3) --

  describe "DAD telemetry" do
    setup do
      alias YellowDog.DhcpClient.DhcpSocket

      {:ok, socket_pid} =
        DhcpSocket.start_link(
          interface: "eth0",
          owner: self(),
          impl: YellowDog.DhcpClient.TelemetryTest.MockDadSocket
        )

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)
      %{socket_pid: socket_pid}
    end

    test "includes interface in :dad, :start metadata when provided", ctx do
      handler_id = attach([:yellow_dog, :dhcp_client, :dad, :start])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      YellowDog.DhcpClient.DAD.check(ctx.socket_pid, {192, 168, 1, 50},
        probes: 1,
        wait_ms: 10,
        interface: "eth0"
      )

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :dad, :start], %{},
                      %{interface: "eth0", ip: "192.168.1.50"}}
    end

    test "omits interface from :dad, :start metadata when not provided", ctx do
      handler_id = attach([:yellow_dog, :dhcp_client, :dad, :start])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      YellowDog.DhcpClient.DAD.check(ctx.socket_pid, {192, 168, 1, 50}, probes: 1, wait_ms: 10)

      assert_receive {:telemetry, _, _, meta}
      refute Map.has_key?(meta, :interface)
    end

    test "includes conflict: false in :dad, :result metadata on no conflict", ctx do
      handler_id = attach([:yellow_dog, :dhcp_client, :dad, :result])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      YellowDog.DhcpClient.DAD.check(ctx.socket_pid, {192, 168, 1, 50},
        probes: 1,
        wait_ms: 10,
        interface: "eth0"
      )

      assert_receive {:telemetry, [:yellow_dog, :dhcp_client, :dad, :result], %{},
                      %{interface: "eth0", ip: "192.168.1.50", conflict: false}}
    end
  end

  # -- event_names/0 --

  describe "event_names/0" do
    test "returns all event name lists" do
      names = Telemetry.event_names()

      assert is_list(names)
      assert length(names) == 12
    end

    test "includes state change event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :state, :change] in names
    end

    test "includes packet tx event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :packet, :tx] in names
    end

    test "includes packet rx event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :packet, :rx] in names
    end

    test "includes lease bound event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :lease, :bound] in names
    end

    test "includes lease renewed event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :lease, :renewed] in names
    end

    test "includes lease expired event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :lease, :expired] in names
    end

    test "includes os apply event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :os, :apply] in names
    end

    test "includes dad start event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :dad, :start] in names
    end

    test "includes dad result event" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :dad, :result] in names
    end

    test "includes config_watcher events" do
      names = Telemetry.event_names()
      assert [:yellow_dog, :dhcp_client, :config_watcher, :started] in names
      assert [:yellow_dog, :dhcp_client, :config_watcher, :change_detected] in names
      assert [:yellow_dog, :dhcp_client, :config_watcher, :reconciled] in names
    end

    test "all events are prefixed with [:yellow_dog, :dhcp_client]" do
      names = Telemetry.event_names()

      Enum.each(names, fn event_name ->
        assert [:yellow_dog, :dhcp_client | _rest] = event_name
      end)
    end
  end
end
