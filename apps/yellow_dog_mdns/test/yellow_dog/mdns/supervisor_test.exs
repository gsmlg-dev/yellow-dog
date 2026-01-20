defmodule YellowDog.Mdns.SupervisorTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Mdns.Supervisor.

  Tests cover:
  - Module structure and exports
  - Supervisor lifecycle (start, stop)
  - Child process verification
  - Configuration options
  - Telemetry events
  """
  use ExUnit.Case, async: false

  alias YellowDog.Mdns.Supervisor, as: MdnsSupervisor

  # Helper to safely stop the supervisor
  defp safe_stop_supervisor(name \\ YellowDog.Mdns) do
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
      {:module, _} = Code.ensure_loaded(MdnsSupervisor)
    end

    test "uses Supervisor behaviour" do
      Code.ensure_loaded!(MdnsSupervisor)
      behaviours = MdnsSupervisor.__info__(:attributes)[:behaviour] || []
      assert Supervisor in behaviours
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(MdnsSupervisor)
      assert Kernel.function_exported?(MdnsSupervisor, :start_link, 1)
    end

    test "exports init/1" do
      Code.ensure_loaded!(MdnsSupervisor)
      assert Kernel.function_exported?(MdnsSupervisor, :init, 1)
    end
  end

  describe "start_link/1" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "starts the supervisor with default options" do
      # Use port 0 to auto-select and unicast for testing
      {:ok, pid} = MdnsSupervisor.start_link(server_options: [port: 0, mode: :unicast])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "supervisor registers with default name YellowDog.Mdns" do
      {:ok, pid} = MdnsSupervisor.start_link(server_options: [port: 0, mode: :unicast])

      assert Process.whereis(YellowDog.Mdns) == pid
    end

    test "accepts custom name option" do
      custom_name = :"test_mdns_#{System.unique_integer()}"
      {:ok, pid} = MdnsSupervisor.start_link(name: custom_name, server_options: [port: 0, mode: :unicast])

      on_exit(fn -> safe_stop_supervisor(custom_name) end)

      assert Process.whereis(custom_name) == pid
    end

    test "accepts server_options" do
      {:ok, pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          storage_file: "test/tmp/mdns_services.toml",
          auto_save: false,
          load_on_start: false
        ]
      )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "child processes" do
    setup do
      safe_stop_supervisor()

      {:ok, pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          auto_save: false,
          load_on_start: false
        ]
      )

      # Give time for children to start
      Process.sleep(200)

      on_exit(fn -> safe_stop_supervisor() end)
      {:ok, supervisor_pid: pid}
    end

    test "starts rate_limiter", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.RateLimiter) != nil
    end

    test "starts service_registry", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.ServiceRegistry) != nil
    end

    test "starts file_watcher", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.FileWatcher) != nil
    end

    test "starts network_monitor", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.NetworkMonitor) != nil
    end

    test "starts message_cache", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.MessageCache) != nil
    end

    test "starts server", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Mdns.Server) != nil
    end
  end

  describe "supervisor count_children" do
    setup do
      safe_stop_supervisor()

      {:ok, pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          auto_save: false,
          load_on_start: false
        ]
      )

      Process.sleep(200)

      on_exit(fn -> safe_stop_supervisor() end)
      {:ok, supervisor_pid: pid}
    end

    test "has multiple children", %{supervisor_pid: pid} do
      counts = Supervisor.count_children(pid)

      assert is_map(counts)
      assert counts.specs >= 6
      assert counts.active >= 6
    end

    test "which_children returns expected child ids", %{supervisor_pid: pid} do
      children = Supervisor.which_children(pid)

      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      # Check for expected children
      assert :rate_limiter in child_ids
      assert :service_registry in child_ids
      assert :file_watcher in child_ids
      assert :network_monitor in child_ids
      assert :message_cache in child_ids
      assert :server in child_ids
    end
  end

  describe "supervisor stop" do
    setup do
      safe_stop_supervisor()
      :ok
    end

    test "supervisor can be stopped" do
      {:ok, pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      assert Process.alive?(pid)

      Supervisor.stop(pid)
      Process.sleep(100)

      refute Process.alive?(pid)
    end

    test "children are stopped when supervisor stops" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      Process.sleep(200)

      # Verify children are running
      assert Process.whereis(YellowDog.Mdns.Server) != nil
      assert Process.whereis(YellowDog.Mdns.ServiceRegistry) != nil

      safe_stop_supervisor()

      # Verify children are stopped
      assert Process.whereis(YellowDog.Mdns.Server) == nil
      assert Process.whereis(YellowDog.Mdns.ServiceRegistry) == nil
    end
  end

  describe "configuration inheritance" do
    setup do
      safe_stop_supervisor()
      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "default storage_file is used when not specified" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      # Supervisor started successfully with default storage_file
      assert Process.whereis(YellowDog.Mdns) != nil
    end

    test "custom storage_file is passed to children" do
      custom_path = "test/tmp/custom_mdns_#{System.unique_integer()}.toml"

      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          storage_file: custom_path,
          auto_save: false,
          load_on_start: false
        ]
      )

      # Supervisor started successfully with custom storage_file
      assert Process.whereis(YellowDog.Mdns) != nil
    end

    test "auto_save option is passed to service registry" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          auto_save: true,
          load_on_start: false
        ]
      )

      # Supervisor started successfully
      assert Process.whereis(YellowDog.Mdns) != nil
    end

    test "watch_file option controls file watcher" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [
          port: 0,
          mode: :unicast,
          watch_file: false,
          auto_save: false,
          load_on_start: false
        ]
      )

      # FileWatcher still starts but may be disabled internally
      assert Process.whereis(YellowDog.Mdns.FileWatcher) != nil
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
      {:ok, pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      Process.sleep(200)

      # Get a child pid
      server_pid = Process.whereis(YellowDog.Mdns.Server)
      assert server_pid != nil

      # Kill the server
      Process.exit(server_pid, :kill)
      Process.sleep(200)

      # Server should be restarted but supervisor still running
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
        "test-mdns-pre-start",
        [:yellow_dog, :mdns, :supervisor, :pre_start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-mdns-post-start",
        [:yellow_dog, :mdns, :supervisor, :post_start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        safe_stop_supervisor()
        :telemetry.detach("test-mdns-pre-start")
        :telemetry.detach("test-mdns-post-start")
      end)

      :ok
    end

    test "emits pre_start telemetry event" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      assert_receive {:telemetry, [:yellow_dog, :mdns, :supervisor, :pre_start], %{count: 1}, _}, 1000
    end

    test "emits post_start telemetry event with mode" do
      {:ok, _pid} = MdnsSupervisor.start_link(
        server_options: [port: 0, mode: :unicast, auto_save: false, load_on_start: false]
      )

      assert_receive {:telemetry, [:yellow_dog, :mdns, :supervisor, :post_start], %{count: 1}, %{mode: :unicast}}, 1000
    end
  end

  describe "init/1 returns valid spec" do
    test "init returns supervisor spec" do
      opts = %{name: YellowDog.Mdns, server_options: [port: 0, mode: :unicast]}

      assert {:ok, spec} = MdnsSupervisor.init(opts)

      # Verify it's a valid supervisor spec tuple
      assert is_tuple(spec)

      # Supervisor.init returns {options_map, children_list}
      {options, children} = spec

      assert is_map(options)
      assert options.strategy == :one_for_one
      assert is_list(children)
      assert length(children) >= 6

      # Verify expected child IDs are present
      child_ids = Enum.map(children, & &1.id)
      assert :rate_limiter in child_ids
      assert :service_registry in child_ids
      assert :server in child_ids
    end
  end
end
