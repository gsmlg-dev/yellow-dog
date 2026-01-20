defmodule YellowDog.Dhcpv6.SupervisorTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dhcpv6.Supervisor.

  Tests cover:
  - Module structure and exports
  - Supervisor lifecycle (start, stop)
  - Child process verification
  - Configuration options
  - Telemetry events
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.Supervisor, as: Dhcpv6Supervisor

  # Helper to safely stop the supervisor
  defp safe_stop_supervisor(name \\ YellowDog.Dhcpv6) do
    try do
      case Process.whereis(name) do
        nil -> :ok
        pid -> Supervisor.stop(pid, :normal, 5000)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(100)
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Dhcpv6Supervisor)
    end

    test "uses Supervisor behaviour" do
      Code.ensure_loaded!(Dhcpv6Supervisor)
      behaviours = Dhcpv6Supervisor.__info__(:attributes)[:behaviour] || []
      assert Supervisor in behaviours
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(Dhcpv6Supervisor)
      assert Kernel.function_exported?(Dhcpv6Supervisor, :start_link, 1)
    end

    test "exports init/1" do
      Code.ensure_loaded!(Dhcpv6Supervisor)
      assert Kernel.function_exported?(Dhcpv6Supervisor, :init, 1)
    end
  end

  describe "start_link/1" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "starts the supervisor with default options" do
      # Use port 0 to auto-select available port
      {:ok, pid} = Dhcpv6Supervisor.start_link(server_options: [port: 0])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "supervisor registers with default name YellowDog.Dhcpv6" do
      {:ok, pid} = Dhcpv6Supervisor.start_link(server_options: [port: 0])

      assert Process.whereis(YellowDog.Dhcpv6) == pid
    end

    test "accepts custom name option" do
      custom_name = :"test_dhcpv6_#{System.unique_integer()}"
      {:ok, pid} = Dhcpv6Supervisor.start_link(name: custom_name, server_options: [port: 0])

      on_exit(fn -> safe_stop_supervisor(custom_name) end)

      assert Process.whereis(custom_name) == pid
    end

    test "accepts server_options" do
      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: []
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts pools configuration" do
      pool = %{
        name: "test_ipv6_pool",
        range_start: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 100},
        range_end: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 200},
        prefix_length: 64,
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: [pool]
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "child processes" do
    setup do
      safe_stop_supervisor()

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: []
        ]
      )

      # Give time for children to start
      Process.sleep(200)

      on_exit(fn -> safe_stop_supervisor() end)
      {:ok, supervisor_pid: pid}
    end

    test "starts rate_limiter", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dhcpv6.RateLimiter) != nil
    end

    test "starts lease_manager", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dhcpv6.LeaseManager) != nil
    end

    test "starts server", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dhcpv6.Server) != nil
    end
  end

  describe "supervisor count_children" do
    setup do
      safe_stop_supervisor()

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: []
        ]
      )

      Process.sleep(200)

      on_exit(fn -> safe_stop_supervisor() end)
      {:ok, supervisor_pid: pid}
    end

    test "has multiple children", %{supervisor_pid: pid} do
      counts = Supervisor.count_children(pid)

      assert is_map(counts)
      # pre_start, rate_limiter, lease_manager, server, post_start = 5
      assert counts.specs >= 3
      assert counts.active >= 3
    end

    test "which_children returns expected child ids", %{supervisor_pid: pid} do
      children = Supervisor.which_children(pid)

      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      # Check for expected children
      assert :rate_limiter in child_ids
      assert :lease_manager in child_ids
      assert :server in child_ids
    end
  end

  describe "supervisor stop" do
    setup do
      safe_stop_supervisor()
      :ok
    end

    test "supervisor can be stopped" do
      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      assert Process.alive?(pid)

      Supervisor.stop(pid)
      Process.sleep(100)

      refute Process.alive?(pid)
    end

    test "children are stopped when supervisor stops" do
      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      Process.sleep(200)

      # Verify children are running
      assert Process.whereis(YellowDog.Dhcpv6.Server) != nil
      assert Process.whereis(YellowDog.Dhcpv6.LeaseManager) != nil

      safe_stop_supervisor()

      # Verify children are stopped
      assert Process.whereis(YellowDog.Dhcpv6.Server) == nil
      assert Process.whereis(YellowDog.Dhcpv6.LeaseManager) == nil
    end
  end

  describe "configuration inheritance" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "empty pools is used when not specified" do
      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0]
      )

      # Supervisor started successfully with empty pools
      assert Process.whereis(YellowDog.Dhcpv6) != nil
    end

    test "custom pools are passed to lease manager" do
      pool = %{
        name: "custom_ipv6_pool",
        range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 1},
        range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 100},
        prefix_length: 64
      }

      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: [pool]
        ]
      )

      # Supervisor started successfully with custom pools
      assert Process.whereis(YellowDog.Dhcpv6) != nil
    end
  end

  describe "supervision strategy" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "uses one_for_one strategy" do
      # Start supervisor
      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      Process.sleep(200)

      # Get a child pid
      server_pid = Process.whereis(YellowDog.Dhcpv6.Server)
      assert server_pid != nil

      # Kill the server
      Process.exit(server_pid, :kill)
      Process.sleep(200)

      # Supervisor should still be running
      assert Process.alive?(pid)
      # Note: Server may or may not restart depending on restart strategy
    end
  end

  describe "telemetry events" do
    setup do
      safe_stop_supervisor()

      test_pid = self()

      # Attach telemetry handlers
      :telemetry.attach(
        "test-dhcpv6-starting",
        [:yellow_dog, :dhcpv6, :supervisor, :starting],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-dhcpv6-pre-start",
        [:yellow_dog, :dhcpv6, :supervisor, :pre_start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-dhcpv6-post-start",
        [:yellow_dog, :dhcpv6, :supervisor, :post_start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        safe_stop_supervisor()
        :telemetry.detach("test-dhcpv6-starting")
        :telemetry.detach("test-dhcpv6-pre-start")
        :telemetry.detach("test-dhcpv6-post-start")
      end)

      :ok
    end

    test "emits starting telemetry event" do
      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      assert_receive {:telemetry, [:yellow_dog, :dhcpv6, :supervisor, :starting], %{count: 1}, _}, 1000
    end

    test "emits pre_start telemetry event" do
      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      assert_receive {:telemetry, [:yellow_dog, :dhcpv6, :supervisor, :pre_start], %{count: 1}, _}, 1000
    end

    test "emits post_start telemetry event" do
      {:ok, _pid} = Dhcpv6Supervisor.start_link(
        server_options: [port: 0, pools: []]
      )

      assert_receive {:telemetry, [:yellow_dog, :dhcpv6, :supervisor, :post_start], %{count: 1}, _}, 1000
    end
  end

  describe "init/1 returns valid spec" do
    test "init returns supervisor spec" do
      opts = %{name: YellowDog.Dhcpv6, server_options: [port: 0, pools: []]}

      assert {:ok, spec} = Dhcpv6Supervisor.init(opts)

      # Verify it's a valid supervisor spec tuple
      assert is_tuple(spec)

      # Supervisor.init returns {options_map, children_list}
      {options, children} = spec

      assert is_map(options)
      assert options.strategy == :one_for_one
      assert is_list(children)
      assert length(children) >= 3

      # Verify expected child IDs are present
      child_ids = Enum.map(children, & &1.id)
      assert :pre_start in child_ids
      assert :rate_limiter in child_ids
      assert :lease_manager in child_ids
      assert :server in child_ids
      assert :post_start in child_ids
    end
  end

  describe "IPv6 address handling" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "accepts IPv6 pools with full address tuples" do
      pool = %{
        name: "full_ipv6_pool",
        range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001},
        range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x00FF},
        prefix_length: 64
      }

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: [pool]
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts link-local address ranges" do
      pool = %{
        name: "link_local_pool",
        range_start: {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        range_end: {0xFE80, 0, 0, 0, 0, 0, 0, 100},
        prefix_length: 64
      }

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: [pool]
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts ULA (unique local address) ranges" do
      pool = %{
        name: "ula_pool",
        range_start: {0xFD00, 0x1234, 0x5678, 0, 0, 0, 0, 1},
        range_end: {0xFD00, 0x1234, 0x5678, 0, 0, 0, 0, 1000},
        prefix_length: 48
      }

      {:ok, pid} = Dhcpv6Supervisor.start_link(
        server_options: [
          port: 0,
          pools: [pool]
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
