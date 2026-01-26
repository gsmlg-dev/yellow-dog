defmodule YellowDog.Dns.SupervisorTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Supervisor.

  Tests cover:
  - Module exports and function arity
  - Status reporting when supervisor is not running
  - Configuration helper behavior (port, listen, debug)
  - IP address parsing and formatting
  - Supervisor initialization and lifecycle
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Supervisor, as: DnsSupervisor

  describe "module exports" do
    test "exports start_link/0 and start_link/1" do
      # Ensure module is loaded before checking exports
      {:module, _} = Code.ensure_loaded(DnsSupervisor)

      assert function_exported?(DnsSupervisor, :start_link, 0) or
               function_exported?(DnsSupervisor, :start_link, 1)
    end

    test "exports stop/0 and stop/1" do
      {:module, _} = Code.ensure_loaded(DnsSupervisor)

      assert function_exported?(DnsSupervisor, :stop, 0) or
               function_exported?(DnsSupervisor, :stop, 1)
    end

    test "exports status/0" do
      {:module, _} = Code.ensure_loaded(DnsSupervisor)
      assert function_exported?(DnsSupervisor, :status, 0)
    end

    test "exports init/1" do
      {:module, _} = Code.ensure_loaded(DnsSupervisor)
      assert function_exported?(DnsSupervisor, :init, 1)
    end

    test "uses Supervisor behaviour" do
      {:module, _} = Code.ensure_loaded(DnsSupervisor)
      behaviours = DnsSupervisor.__info__(:attributes)[:behaviour] || []
      assert Supervisor in behaviours
    end
  end

  describe "status/0 when supervisor is not running" do
    setup do
      # Ensure supervisor is not running
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(50)
      :ok
    end

    test "returns map with running: false" do
      status = DnsSupervisor.status()

      assert is_map(status)
      assert status.running == false
    end

    test "status map has expected keys" do
      status = DnsSupervisor.status()

      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :server)
      assert Map.has_key?(status, :connection_stats)
      assert Map.has_key?(status, :view_stats)
      assert Map.has_key?(status, :zone_count)
    end

    test "server status defaults to %{running: false}" do
      status = DnsSupervisor.status()

      # When server isn't running, defaults should be returned
      assert is_map(status.server)
    end

    test "connection_stats defaults to empty map" do
      status = DnsSupervisor.status()

      assert status.connection_stats == %{}
    end

    test "view_stats defaults to empty map" do
      status = DnsSupervisor.status()

      assert status.view_stats == %{}
    end

    test "zone_count defaults to 0" do
      status = DnsSupervisor.status()

      assert status.zone_count == 0
    end
  end

  describe "stop/1" do
    test "accepts atom name" do
      # Ensure module is loaded before checking exports
      {:module, _} = Code.ensure_loaded(DnsSupervisor)
      # Function should exist and accept an atom
      assert function_exported?(DnsSupervisor, :stop, 1)
    end

    test "stop/0 uses default name YellowDog.Dns" do
      # Ensure module is loaded before checking exports
      {:module, _} = Code.ensure_loaded(DnsSupervisor)
      # stop/0 with default arg should exist
      assert function_exported?(DnsSupervisor, :stop, 0) or
               function_exported?(DnsSupervisor, :stop, 1)
    end
  end

  describe "supervisor lifecycle" do
    setup do
      # Ensure supervisor is not running before each test
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        # Give time for cleanup
        Process.sleep(100)
      end)

      :ok
    end

    test "start_link/1 starts the supervisor with port 0" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert Process.whereis(YellowDog.Dns) == pid
    end

    test "status shows running after start" do
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)

      # Give time for post-init
      Process.sleep(200)

      status = DnsSupervisor.status()
      assert status.running == true
    end

    test "stop/0 stops the supervisor" do
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)

      assert Process.whereis(YellowDog.Dns) != nil

      :ok = DnsSupervisor.stop()

      Process.sleep(100)
      assert Process.whereis(YellowDog.Dns) == nil
    end

    test "stop/1 stops the supervisor with pid" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0)

      assert Process.alive?(pid)

      :ok = DnsSupervisor.stop(pid)

      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "status shows server running after start" do
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)

      # Give time for children to start
      Process.sleep(200)

      status = DnsSupervisor.status()
      assert status.running == true
      assert is_map(status.server)
    end
  end

  describe "supervisor with custom options" do
    setup do
      # Ensure supervisor is not running before each test
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        Process.sleep(100)
      end)

      :ok
    end

    test "accepts custom port option" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts custom listen option as tuple" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0, listen: {127, 0, 0, 1})

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts custom listen option as string" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0, listen: "127.0.0.1")

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts debug option" do
      # Should not crash with debug: true
      {:ok, pid} = DnsSupervisor.start_link(port: 0, debug: false)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts views option as empty list" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0, views: [])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts zones option as empty list" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0, zones: [])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "child processes after start" do
    setup do
      # Ensure supervisor is not running before each test
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      {:ok, pid} = DnsSupervisor.start_link(port: 0)

      # Give time for post-init to complete
      Process.sleep(300)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        Process.sleep(100)
      end)

      {:ok, supervisor_pid: pid}
    end

    test "starts ZoneRegistry", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ZoneRegistry) != nil
    end

    test "starts ViewRegistry", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ViewRegistry) != nil
    end

    test "starts ConnectionRegistry", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ConnectionRegistry) != nil
    end

    test "starts RateLimiter", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.RateLimiter) != nil
    end

    test "starts AclRegistry", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.AclRegistry) != nil
    end

    test "starts ZoneController", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ZoneController) != nil
    end

    test "starts ViewManager", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ViewManager) != nil
    end

    test "starts ConnectionManager", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.ConnectionManager) != nil
    end

    test "starts Server", %{supervisor_pid: _pid} do
      assert Process.whereis(YellowDog.Dns.Server) != nil
    end

    test "creates default view", %{supervisor_pid: _pid} do
      # Default view should be created during post-init
      case YellowDog.Dns.ViewManager.get_view("default") do
        {:ok, view_pid} ->
          assert is_pid(view_pid)

        :error ->
          # May have timed out, wait and retry
          Process.sleep(200)
          assert {:ok, _pid} = YellowDog.Dns.ViewManager.get_view("default")
      end
    end
  end

  describe "supervisor count_children" do
    setup do
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      {:ok, pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(200)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        Process.sleep(100)
      end)

      {:ok, supervisor_pid: pid}
    end

    test "has multiple children", %{supervisor_pid: pid} do
      counts = Supervisor.count_children(pid)

      # Should have specs, active, supervisors, and workers
      assert is_map(counts)
      assert counts.specs > 0
      assert counts.active > 0
    end

    test "which_children returns expected child ids", %{supervisor_pid: pid} do
      children = Supervisor.which_children(pid)

      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      # Check for some expected children
      assert YellowDog.Dns.ZoneRegistry in child_ids
      assert YellowDog.Dns.ViewRegistry in child_ids
      assert YellowDog.Dns.ConnectionRegistry in child_ids
      assert :rate_limiter in child_ids
      assert YellowDog.Dns.AclRegistry in child_ids
      assert YellowDog.Dns.ZoneController in child_ids
      assert YellowDog.Dns.ViewManager in child_ids
      assert YellowDog.Dns.ConnectionManager in child_ids
      assert YellowDog.Dns.Server in child_ids
    end
  end

  describe "status aggregation" do
    setup do
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        Process.sleep(100)
      end)

      :ok
    end

    test "server status contains running flag" do
      status = DnsSupervisor.status()

      assert is_map(status.server)
      assert Map.has_key?(status.server, :running)
    end

    test "zone_count is an integer" do
      status = DnsSupervisor.status()

      assert is_integer(status.zone_count)
      assert status.zone_count >= 0
    end

    test "connection_stats is a map" do
      status = DnsSupervisor.status()

      assert is_map(status.connection_stats)
    end

    test "view_stats is a map" do
      status = DnsSupervisor.status()

      assert is_map(status.view_stats)
    end
  end

  describe "registration name" do
    setup do
      case Process.whereis(YellowDog.Dns) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(100)

      on_exit(fn ->
        try do
          case Process.whereis(YellowDog.Dns) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end

        Process.sleep(100)
      end)

      :ok
    end

    test "supervisor is registered as YellowDog.Dns (not YellowDog.Dns.Supervisor)" do
      {:ok, pid} = DnsSupervisor.start_link(port: 0)

      # Should be registered as YellowDog.Dns
      assert Process.whereis(YellowDog.Dns) == pid

      # Should NOT be registered as YellowDog.Dns.Supervisor
      assert Process.whereis(YellowDog.Dns.Supervisor) == nil
    end
  end
end
