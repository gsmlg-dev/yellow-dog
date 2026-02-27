defmodule YellowDog.Dhcpv6.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Dhcpv6.Server

  # ── Module structure ────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Server} = Code.ensure_loaded(Server)
    end

    test "exports start_link/1" do
      assert is_function(&Server.start_link/1)
    end

    test "exports stop/0 and stop/1" do
      assert is_function(&Server.stop/0)
      assert is_function(&Server.stop/1)
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
      assert Map.has_key?(config, :transport_module)
      assert Map.has_key?(config, :handler_module)
      assert Map.has_key?(config, :transport_options)
      assert Map.has_key?(config, :read_timeout)
      assert Map.has_key?(config, :num_listeners)
      assert Map.has_key?(config, :max_packet_size)
    end

    test "default port is 547 (DHCPv6 standard)" do
      config = Server.get_config()
      assert config.port == 547
    end

    test "uses Broadcast transport module" do
      config = Server.get_config()
      assert config.transport_module == Abyss.Transport.UDP.Broadcast
    end

    test "uses DHCPv6 Handler module" do
      config = Server.get_config()
      assert config.handler_module == YellowDog.Dhcpv6.Handler
    end

    test "transport_options include IPv6 bind address" do
      config = Server.get_config()
      assert Keyword.get(config.transport_options, :ip) == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "transport_options include ipv6_v6only" do
      config = Server.get_config()
      assert Keyword.get(config.transport_options, :ipv6_v6only) == true
    end

    test "transport_options include reuseaddr" do
      config = Server.get_config()
      assert Keyword.get(config.transport_options, :reuseaddr) == true
    end

    test "max_packet_size is 1500 (DHCPv6 allows larger)" do
      config = Server.get_config()
      assert config.max_packet_size == 1500
    end

    test "num_listeners defaults to 10" do
      config = Server.get_config()
      assert config.num_listeners == 10
    end
  end

  # ── start_link/1 and stop ──────────────────────────────────────

  describe "start_link/1 and stop/1" do
    test "starts and stops the server on ephemeral port" do
      log =
        capture_log(fn ->
          assert {:ok, pid} = Server.start_link(port: 0)
          assert Process.alive?(pid)

          :ok = Server.stop(pid)
          refute Process.alive?(pid)
        end)

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

        assert {:error, {:already_started, ^pid}} = Server.start_link(port: 0)

        Server.stop(pid)
      end)
    end

    test "passes custom listen address via opts" do
      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0, listen: {0, 0, 0, 0, 0, 0, 0, 1})
        assert Process.alive?(pid)
        Server.stop(pid)
      end)
    end

    test "filters DHCP-specific keys from Abyss config" do
      # pools, static_reservations, data_dir should be silently removed
      capture_log(fn ->
        {:ok, pid} =
          Server.start_link(
            port: 0,
            pools: [],
            static_reservations: [],
            data_dir: "/tmp"
          )

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
        "test-dhcpv6-starting",
        [:yellow_dog, :dhcpv6, :server, :starting],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:starting, measurements, metadata})
        end,
        nil
      )

      capture_log(fn ->
        {:ok, pid} = Server.start_link(port: 0)

        assert_receive {:starting, %{count: 1}, metadata}
        assert is_integer(metadata.port)

        Server.stop(pid)
      end)

      :telemetry.detach("test-dhcpv6-starting")
    end

    test "emits :started telemetry after successful start" do
      test_pid = self()

      :telemetry.attach(
        "test-dhcpv6-started",
        [:yellow_dog, :dhcpv6, :server, :started],
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

      :telemetry.detach("test-dhcpv6-started")
    end

    test "emits :stopping telemetry on terminate" do
      test_pid = self()

      :telemetry.attach(
        "test-dhcpv6-stopping",
        [:yellow_dog, :dhcpv6, :server, :stopping],
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

      :telemetry.detach("test-dhcpv6-stopping")
    end
  end
end
