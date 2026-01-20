defmodule YellowDog.Dns.View.OperationsTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.View.Operations.

  Tests cover:
  - Module structure and exports
  - Status reporting
  - Health check functionality
  - Metrics collection
  - View listing and details
  - Client match testing
  - Configuration reload triggers
  - Error handling when system unavailable
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.View.Operations
  alias YellowDog.Dns.Supervisor, as: DnsSupervisor

  # Helper to safely stop the supervisor
  defp safe_stop_supervisor do
    try do
      case Process.whereis(YellowDog.Dns) do
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
      {:module, _} = Code.ensure_loaded(Operations)
    end

    test "exports status/0" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :status, 0)
    end

    test "exports health_check/0" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :health_check, 0)
    end

    test "exports get_metrics/0" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :get_metrics, 0)
    end

    test "exports list_views/0" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :list_views, 0)
    end

    test "exports get_view_info/1" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :get_view_info, 1)
    end

    test "exports test_client_match/1" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :test_client_match, 1)
    end

    test "exports trigger_reload/0" do
      Code.ensure_loaded!(Operations)
      assert Kernel.function_exported?(Operations, :trigger_reload, 0)
    end
  end

  describe "status/0 without ViewManager running" do
    # Note: The Operations module uses try/rescue which doesn't catch exit signals
    # from GenServer.call when ViewManager is not running
    setup do
      safe_stop_supervisor()
      :ok
    end

    test "raises exit when ViewManager not running" do
      # Without ViewManager, GenServer.call exits with :noproc
      # The Operations module currently uses rescue instead of catch :exit
      assert catch_exit(Operations.status()) != nil
    end
  end

  describe "status/0 with ViewManager running" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple with status map" do
      result = Operations.status()

      assert {:ok, status} = result
      assert is_map(status)
    end

    test "status contains manager section" do
      {:ok, status} = Operations.status()

      assert Map.has_key?(status, :manager)
      assert is_map(status.manager)
    end

    test "manager section has view_count" do
      {:ok, status} = Operations.status()

      assert Map.has_key?(status.manager, :view_count)
      assert is_integer(status.manager.view_count)
      assert status.manager.view_count >= 0
    end

    test "manager section has view_names list" do
      {:ok, status} = Operations.status()

      assert Map.has_key?(status.manager, :view_names)
      assert is_list(status.manager.view_names)
    end

    test "status contains watcher section" do
      {:ok, status} = Operations.status()

      assert Map.has_key?(status, :watcher)
      assert is_map(status.watcher)
    end

    test "watcher status indicates not running" do
      {:ok, status} = Operations.status()

      assert status.watcher.status == :not_running
      assert status.watcher.watching == false
    end

    test "status contains health section" do
      {:ok, status} = Operations.status()

      assert Map.has_key?(status, :health)
    end
  end

  describe "health_check/0" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple" do
      result = Operations.health_check()

      assert {:ok, health} = result
      assert is_map(health)
    end

    test "health check has status field" do
      {:ok, health} = Operations.health_check()

      assert Map.has_key?(health, :status)
    end

    test "health check has checks field" do
      {:ok, health} = Operations.health_check()

      assert Map.has_key?(health, :checks)
      assert is_map(health.checks)
    end

    test "health check includes view_manager check" do
      {:ok, health} = Operations.health_check()

      assert health.checks.view_manager == :passing
    end

    test "health check includes config_watcher check" do
      {:ok, health} = Operations.health_check()

      assert health.checks.config_watcher == :not_applicable
    end

    test "health check has details field" do
      {:ok, health} = Operations.health_check()

      assert Map.has_key?(health, :details)
      assert is_map(health.details)
    end
  end

  describe "get_metrics/0" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple with metrics" do
      result = Operations.get_metrics()

      assert {:ok, metrics} = result
      assert is_map(metrics)
    end

    test "metrics contains views section" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics, :views)
      assert is_map(metrics.views)
    end

    test "views metrics has count" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics.views, :count)
      assert is_integer(metrics.views.count)
    end

    test "views metrics has names list" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics.views, :names)
      assert is_list(metrics.views.names)
    end

    test "metrics contains reloads section" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics, :reloads)
      assert is_map(metrics.reloads)
    end

    test "reloads metrics has expected fields" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics.reloads, :total)
      assert Map.has_key?(metrics.reloads, :successful)
      assert Map.has_key?(metrics.reloads, :failed)
      assert Map.has_key?(metrics.reloads, :last_reload)
    end

    test "metrics contains operations section" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics, :operations)
      assert is_map(metrics.operations)
    end

    test "operations metrics has expected fields" do
      {:ok, metrics} = Operations.get_metrics()

      assert Map.has_key?(metrics.operations, :update_count)
      assert Map.has_key?(metrics.operations, :last_update)
    end
  end

  describe "list_views/0" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple with list" do
      result = Operations.list_views()

      assert {:ok, views} = result
      assert is_list(views)
    end

    test "view entries are maps" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert is_map(view)
      end)
    end

    test "view entries have name field" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert Map.has_key?(view, :name)
      end)
    end

    test "view entries have match_clients field" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert Map.has_key?(view, :match_clients)
      end)
    end

    test "view entries have zone_count field" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert Map.has_key?(view, :zone_count)
        assert is_integer(view.zone_count)
      end)
    end

    test "view entries have zones list" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert Map.has_key?(view, :zones)
        assert is_list(view.zones)
      end)
    end

    test "view entries have recursion_enabled field" do
      {:ok, views} = Operations.list_views()

      Enum.each(views, fn view ->
        assert Map.has_key?(view, :recursion_enabled)
        assert is_boolean(view.recursion_enabled)
      end)
    end
  end

  describe "get_view_info/1" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple for existing view" do
      result = Operations.get_view_info("default")

      assert {:ok, view} = result
      assert is_map(view)
    end

    test "returns error for non-existent view" do
      result = Operations.get_view_info("nonexistent_view_12345")

      assert result == {:error, :view_not_found}
    end

    test "view info has name field" do
      {:ok, view} = Operations.get_view_info("default")

      assert view.name == "default"
    end

    test "view info has match_clients field" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view, :match_clients)
    end

    test "view info has zone_count field" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view, :zone_count)
      assert is_integer(view.zone_count)
    end

    test "view info has zones list" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view, :zones)
      assert is_list(view.zones)
    end

    test "view info has recursion_enabled field" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view, :recursion_enabled)
      assert is_boolean(view.recursion_enabled)
    end

    test "view info has match_clients_details section" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view, :match_clients_details)
      assert is_map(view.match_clients_details)
    end

    test "match_clients_details has type field" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view.match_clients_details, :type)
    end

    test "match_clients_details has pattern field" do
      {:ok, view} = Operations.get_view_info("default")

      assert Map.has_key?(view.match_clients_details, :pattern)
    end
  end

  describe "test_client_match/1" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "returns ok tuple for valid IPv4 address" do
      result = Operations.test_client_match({192, 168, 1, 100})

      assert {:ok, match} = result
      assert is_map(match)
    end

    test "returns ok tuple for loopback IPv4" do
      result = Operations.test_client_match({127, 0, 0, 1})

      assert {:ok, match} = result
      assert is_map(match)
    end

    test "returns ok tuple for IPv6 address" do
      result = Operations.test_client_match({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      assert {:ok, match} = result
      assert is_map(match)
    end

    test "match result has client_ip field" do
      {:ok, match} = Operations.test_client_match({192, 168, 1, 100})

      assert Map.has_key?(match, :client_ip)
      assert is_binary(match.client_ip)
    end

    test "match result has matched_view field" do
      {:ok, match} = Operations.test_client_match({192, 168, 1, 100})

      assert Map.has_key?(match, :matched_view)
    end

    test "match result has recursion_enabled field" do
      {:ok, match} = Operations.test_client_match({192, 168, 1, 100})

      assert Map.has_key?(match, :recursion_enabled)
      assert is_boolean(match.recursion_enabled)
    end

    test "match result has accessible_zones field" do
      {:ok, match} = Operations.test_client_match({192, 168, 1, 100})

      assert Map.has_key?(match, :accessible_zones)
      assert is_list(match.accessible_zones)
    end
  end

  describe "test_client_match/1 without views" do
    # Note: The Operations module uses try/rescue which doesn't catch exit signals
    # from GenServer.call, so we test the exit behavior directly
    setup do
      safe_stop_supervisor()
      :ok
    end

    test "raises exit when ViewManager not running" do
      # Without ViewManager, GenServer.call exits with :noproc
      # The Operations module currently uses rescue instead of catch :exit
      assert catch_exit(Operations.test_client_match({192, 168, 1, 100})) != nil
    end
  end

  describe "trigger_reload/0" do
    test "returns error when watcher not running" do
      result = Operations.trigger_reload()

      assert result == {:error, :watcher_not_running}
    end
  end

  describe "IP address formatting" do
    setup do
      safe_stop_supervisor()
      {:ok, _pid} = DnsSupervisor.start_link(port: 0)
      Process.sleep(300)

      on_exit(fn -> safe_stop_supervisor() end)
      :ok
    end

    test "formats IPv4 address correctly" do
      {:ok, match} = Operations.test_client_match({192, 168, 1, 100})

      assert match.client_ip == "192.168.1.100"
    end

    test "formats loopback IPv4 correctly" do
      {:ok, match} = Operations.test_client_match({127, 0, 0, 1})

      assert match.client_ip == "127.0.0.1"
    end

    test "formats IPv6 address" do
      {:ok, match} = Operations.test_client_match({0, 0, 0, 0, 0, 0, 0, 1})

      # IPv6 loopback should be formatted
      assert is_binary(match.client_ip)
      assert String.contains?(match.client_ip, ":") or match.client_ip == "::1"
    end
  end
end
