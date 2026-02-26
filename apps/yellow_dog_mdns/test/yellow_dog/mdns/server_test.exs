defmodule YellowDog.Mdns.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Mdns.Server

  # ── Module structure ────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Server} = Code.ensure_loaded(Server)
    end

    test "exports start_link/1" do
      assert is_function(&Server.start_link/1)
    end

    test "exports stop/1" do
      assert is_function(&Server.stop/1)
    end

    test "exports send_multicast/1" do
      assert is_function(&Server.send_multicast/1)
    end

    test "exports get_config/0" do
      assert is_function(&Server.get_config/0)
    end
  end

  # ── get_config/0 ────────────────────────────────────────────────

  describe "get_config/0" do
    test "returns map with expected keys" do
      config = Server.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :listen_address)
      assert Map.has_key?(config, :multicast_address)
    end

    test "default port is 5353 (mDNS standard)" do
      config = Server.get_config()
      assert config.port == 5353
    end

    test "default listen address is 0.0.0.0" do
      config = Server.get_config()
      assert config.listen_address == {0, 0, 0, 0}
    end

    test "default multicast address is 224.0.0.251" do
      config = Server.get_config()
      assert config.multicast_address == {224, 0, 0, 251}
    end
  end

  # ── start_link/1 with server start/stop ─────────────────────────

  describe "start_link/1 and stop/1" do
    test "starts and stops the server on ephemeral port" do
      log =
        capture_log(fn ->
          # Use port 0 for ephemeral port to avoid conflicts
          assert {:ok, pid} = Server.start_link(port: 0)
          assert Process.alive?(pid)

          # Stop cleanly
          :ok = Server.stop(pid)
          refute Process.alive?(pid)
        end)

      # Should have logged starting telemetry
      assert is_binary(log)
    end

    test "server registers with its module name" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)
        assert Process.whereis(Server) == pid

        Server.stop(pid)
      end)
    end

    test "start_link fails if already running" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)

        # Second start should fail (named process)
        assert {:error, {:already_started, ^pid}} = Server.start_link(port: 0)

        Server.stop(pid)
      end)
    end

    test "passes custom listen_address" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0, listen_address: {127, 0, 0, 1})
        assert Process.alive?(pid)
        Server.stop(pid)
      end)
    end
  end

  # ── Telemetry events ────────────────────────────────────────────

  describe "telemetry events" do
    test "emits :starting telemetry on init" do
      test_pid = self()

      :telemetry.attach(
        "test-mdns-starting",
        [:yellow_dog, :mdns, :server, :starting],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:starting, measurements, metadata})
        end,
        nil
      )

      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)

        assert_receive {:starting, %{count: 1}, metadata}
        assert is_integer(metadata.port)
        assert metadata.mode in [:hybrid, :responder, :querier]

        Server.stop(pid)
      end)

      :telemetry.detach("test-mdns-starting")
    end

    test "emits :started telemetry after successful start" do
      test_pid = self()

      :telemetry.attach(
        "test-mdns-started",
        [:yellow_dog, :mdns, :server, :started],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:started, measurements, metadata})
        end,
        nil
      )

      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)

        assert_receive {:started, %{count: 1}, metadata}
        assert is_integer(metadata.port)

        Server.stop(pid)
      end)

      :telemetry.detach("test-mdns-started")
    end

    test "emits :stopping telemetry on terminate" do
      test_pid = self()

      :telemetry.attach(
        "test-mdns-stopping",
        [:yellow_dog, :mdns, :server, :stopping],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:stopping, measurements})
        end,
        nil
      )

      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)
        Server.stop(pid)

        assert_receive {:stopping, %{count: 1}}
      end)

      :telemetry.detach("test-mdns-stopping")
    end
  end

  # ── Mode configuration ──────────────────────────────────────────

  describe "mode configuration" do
    test "defaults to hybrid mode" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)

        assert Application.get_env(:yellow_dog_mdns, :mode) == :hybrid

        Server.stop(pid)
      end)
    end

    test "accepts custom mode option" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0, mode: :responder)

        assert Application.get_env(:yellow_dog_mdns, :mode) == :responder

        Server.stop(pid)
      end)
    end
  end
end
