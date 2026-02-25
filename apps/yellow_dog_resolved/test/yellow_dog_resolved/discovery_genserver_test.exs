defmodule YellowDog.Resolved.Discovery.GenServerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Discovery

  @config %{
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 200,
    upstream_failure_threshold: 3,
    discovery: %{
      enabled: true,
      websocket: %{
        heartbeat_interval_s: 30,
        reconnect_base_s: 5,
        reconnect_max_s: 60
      }
    }
  }

  describe "start_link/1" do
    test "starts the discovery GenServer" do
      assert {:ok, pid} = start_supervised({Discovery, @config})
      assert Process.alive?(pid)
    end
  end

  describe "status/0" do
    setup do
      start_supervised!({Discovery, @config})
      :ok
    end

    test "returns status map with instance_id" do
      status = Discovery.status()

      assert is_binary(status.instance_id)
      # Instance ID is 16 bytes hex-encoded = 32 chars
      assert String.length(status.instance_id) == 32
    end

    test "initially not connected" do
      status = Discovery.status()

      assert status.connected == false
      assert status.ws_endpoint == nil
    end
  end

  describe "probe message" do
    test "probe does not crash the process" do
      # The :probe message is sent 1s after init. Since upstreams are unreachable,
      # it should simply fail to find any YellowDog DNS and continue.
      start_supervised!({Discovery, @config})
      pid = Process.whereis(Discovery)

      # Manually trigger probe early
      send(pid, :probe)
      Process.sleep(50)

      assert Process.alive?(pid)
      # Still not connected after failed probe
      assert Discovery.status().connected == false
    end
  end

  describe "reconnect message" do
    test "reconnect does not crash the process" do
      start_supervised!({Discovery, @config})
      pid = Process.whereis(Discovery)

      send(pid, :reconnect)
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "management process DOWN" do
    test "handles DOWN from management pid" do
      start_supervised!({Discovery, @config})
      pid = Process.whereis(Discovery)

      # Simulate a management connection going down
      # Since management_pid is nil, this should be ignored by catch-all
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      send(pid, {:DOWN, make_ref(), :process, fake_pid, :normal})
      Process.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "catch-all handle_info" do
    test "ignores unexpected messages" do
      start_supervised!({Discovery, @config})
      pid = Process.whereis(Discovery)

      send(pid, :unexpected_message)
      send(pid, {:random, :data})
      Process.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "telemetry events during probe" do
    test "emits probe telemetry event" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "discovery-probe-#{inspect(ref)}",
        [:yellow_dog, :resolved, :discovery, :probe],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:probe_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("discovery-probe-#{inspect(ref)}") end)

      start_supervised!({Discovery, @config})

      # Manually trigger probe
      send(Process.whereis(Discovery), :probe)

      assert_receive {:probe_event, %{upstream: {198, 51, 100, 1}}}, 1000
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      start_supervised!({Discovery, @config})

      pid = Process.whereis(Discovery)
      assert Process.alive?(pid)

      stop_supervised!(Discovery)

      refute Process.alive?(pid)
    end
  end
end
