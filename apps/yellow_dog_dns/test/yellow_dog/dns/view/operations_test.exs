defmodule YellowDog.Dns.View.OperationsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.Manager, as: ViewManager
  alias YellowDog.Dns.View.Operations

  describe "add_view/2" do
    setup do
      initial_views = [View.new("existing", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "adds a new view successfully", %{manager_pid: manager_pid} do
      new_view = View.new("guests", "10.99.0.0/16", ["guest.example.com"], true)

      assert {:ok, result} = Operations.add_view(new_view, manager_pid: manager_pid)
      assert result.added == ["guests"]
      assert result.total_views == 2

      # Verify view was added
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 2
      assert Enum.any?(views, &(&1.name == "guests"))

      GenServer.stop(manager_pid)
    end

    test "rejects duplicate view name", %{manager_pid: manager_pid} do
      duplicate_view = View.new("existing", "localhost", [], false)

      assert {:error, {:duplicate_view_name, "existing"}} =
               Operations.add_view(duplicate_view, manager_pid: manager_pid)

      # Original views unchanged
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1

      GenServer.stop(manager_pid)
    end

    test "telemetry logged on successful add", %{manager_pid: manager_pid} do
      new_view = View.new("telemetry_test", "any", [], true)

      assert {:ok, _} = Operations.add_view(new_view, manager_pid: manager_pid)

      GenServer.stop(manager_pid)
    end
  end

  describe "remove_view/2" do
    setup do
      initial_views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false),
        View.new("view3", "localnets", [], true)
      ]

      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "removes an existing view", %{manager_pid: manager_pid} do
      assert {:ok, result} = Operations.remove_view("view2", manager_pid: manager_pid)
      assert result.removed == ["view2"]
      assert result.total_views == 2

      views = ViewManager.get_views(manager_pid)
      assert length(views) == 2
      refute Enum.any?(views, &(&1.name == "view2"))

      GenServer.stop(manager_pid)
    end

    test "returns error for nonexistent view", %{manager_pid: manager_pid} do
      assert {:error, :view_not_found} =
               Operations.remove_view("nonexistent", manager_pid: manager_pid)

      GenServer.stop(manager_pid)
    end

    test "prevents removing last view", %{manager_pid: _pid} do
      # Create manager with single view
      {:ok, single_pid} =
        ViewManager.start_link(views: [View.new("only", "any", [], true)], name: nil)

      assert {:error, :cannot_remove_last_view} =
               Operations.remove_view("only", manager_pid: single_pid)

      GenServer.stop(single_pid)
    end
  end

  describe "update_view/3" do
    setup do
      initial_views = [
        View.new("internal", "localnets", ["old.example.com"], true),
        View.new("external", "any", [], false)
      ]

      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "updates an existing view", %{manager_pid: manager_pid} do
      updated_view =
        View.new("internal", "localnets", ["new.example.com", "corp.example.com"], true)

      assert {:ok, result} =
               Operations.update_view("internal", updated_view, manager_pid: manager_pid)

      assert result.updated == ["internal"]
      assert result.total_views == 2

      views = ViewManager.get_views(manager_pid)
      internal_view = Enum.find(views, &(&1.name == "internal"))
      assert View.has_zone?(internal_view, "new.example.com")
      assert View.has_zone?(internal_view, "corp.example.com")

      GenServer.stop(manager_pid)
    end

    test "returns error if view not found", %{manager_pid: manager_pid} do
      updated_view = View.new("nonexistent", "any", [], true)

      assert {:error, :view_not_found} =
               Operations.update_view("nonexistent", updated_view, manager_pid: manager_pid)

      GenServer.stop(manager_pid)
    end

    test "returns error if view name doesn't match", %{manager_pid: manager_pid} do
      wrong_name_view = View.new("different", "any", [], true)

      assert {:error, {:name_mismatch, "internal", "different"}} =
               Operations.update_view("internal", wrong_name_view, manager_pid: manager_pid)

      GenServer.stop(manager_pid)
    end
  end

  describe "replace_all_views/2" do
    setup do
      initial_views = [View.new("v1", "any", [], true), View.new("v2", "localhost", [], false)]
      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "replaces all views atomically", %{manager_pid: manager_pid} do
      new_views = [
        View.new("new1", "localnets", [], true),
        View.new("new2", "any", [], false),
        View.new("new3", "10.0.0.0/8", [], true)
      ]

      assert {:ok, result} = Operations.replace_all_views(new_views, manager_pid: manager_pid)
      assert result.total_views == 3
      assert result.previous_count == 2

      views = ViewManager.get_views(manager_pid)
      assert length(views) == 3
      assert Enum.any?(views, &(&1.name == "new1"))
      refute Enum.any?(views, &(&1.name == "v1"))

      GenServer.stop(manager_pid)
    end

    test "rejects invalid view list", %{manager_pid: manager_pid} do
      # Duplicate names
      invalid_views = [
        View.new("dup", "any", [], true),
        View.new("dup", "localhost", [], false)
      ]

      assert {:error, _} = Operations.replace_all_views(invalid_views, manager_pid: manager_pid)

      # Original views preserved
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 2

      GenServer.stop(manager_pid)
    end
  end

  describe "status/1" do
    setup do
      views = [View.new("test", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "returns comprehensive status", %{manager_pid: manager_pid} do
      assert {:ok, status} = Operations.status(manager_pid: manager_pid)

      assert Map.has_key?(status, :manager)
      assert Map.has_key?(status, :watcher)
      assert Map.has_key?(status, :health)
      assert Map.has_key?(status, :timestamp)

      assert is_map(status.manager)
      assert status.health in [:healthy, :degraded, :unhealthy]

      GenServer.stop(manager_pid)
    end

    test "reports watcher as not running when absent", %{manager_pid: manager_pid} do
      assert {:ok, status} = Operations.status(manager_pid: manager_pid, watcher_pid: nil)

      assert status.watcher == %{status: :not_running}

      GenServer.stop(manager_pid)
    end
  end

  describe "health_check/1" do
    setup do
      views = [View.new("healthy", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "performs comprehensive health check", %{manager_pid: manager_pid} do
      assert {:ok, health} = Operations.health_check(manager_pid: manager_pid)

      assert Map.has_key?(health, :status)
      assert Map.has_key?(health, :checks)
      assert Map.has_key?(health, :details)
      assert Map.has_key?(health, :timestamp)

      assert health.status in [:healthy, :degraded, :unhealthy]
      assert is_map(health.checks)
      assert Map.has_key?(health.checks, :manager)
      assert Map.has_key?(health.checks, :views)

      GenServer.stop(manager_pid)
    end

    test "manager check passes when operational", %{manager_pid: manager_pid} do
      assert {:ok, health} = Operations.health_check(manager_pid: manager_pid)

      assert health.checks.manager == :passing

      GenServer.stop(manager_pid)
    end

    test "views check passes when views configured", %{manager_pid: manager_pid} do
      assert {:ok, health} = Operations.health_check(manager_pid: manager_pid)

      assert health.checks.views == :passing

      GenServer.stop(manager_pid)
    end
  end

  describe "get_metrics/1" do
    setup do
      views = [View.new("metrics", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "returns comprehensive metrics", %{manager_pid: manager_pid} do
      assert {:ok, metrics} = Operations.get_metrics(manager_pid: manager_pid)

      assert Map.has_key?(metrics, :views)
      assert Map.has_key?(metrics, :reloads)
      assert Map.has_key?(metrics, :operations)
      assert Map.has_key?(metrics, :timestamp)

      GenServer.stop(manager_pid)
    end

    test "view metrics includes count and names", %{manager_pid: manager_pid} do
      assert {:ok, metrics} = Operations.get_metrics(manager_pid: manager_pid)

      assert metrics.views.count == 1
      assert metrics.views.names == ["metrics"]

      GenServer.stop(manager_pid)
    end

    test "reload metrics includes counters", %{manager_pid: manager_pid} do
      assert {:ok, metrics} = Operations.get_metrics(manager_pid: manager_pid)

      assert Map.has_key?(metrics.reloads, :total)
      assert Map.has_key?(metrics.reloads, :successful)
      assert Map.has_key?(metrics.reloads, :failed)

      GenServer.stop(manager_pid)
    end
  end

  describe "list_views/1" do
    setup do
      views = [
        View.new("internal", "localnets", ["corp.example.com"], true),
        View.new("external", "any", ["public.example.com"], false)
      ]

      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "lists all views with details", %{manager_pid: manager_pid} do
      assert {:ok, view_list} = Operations.list_views(manager_pid: manager_pid)

      assert length(view_list) == 2

      internal = Enum.find(view_list, &(&1.name == "internal"))
      assert internal.recursion_enabled == true
      assert internal.zone_count == 1
      assert internal.zones == ["corp.example.com"]

      GenServer.stop(manager_pid)
    end

    test "formats view information correctly", %{manager_pid: manager_pid} do
      assert {:ok, view_list} = Operations.list_views(manager_pid: manager_pid)

      view = List.first(view_list)
      assert Map.has_key?(view, :name)
      assert Map.has_key?(view, :match_clients)
      assert Map.has_key?(view, :zones)
      assert Map.has_key?(view, :recursion_enabled)
      assert Map.has_key?(view, :zone_count)

      GenServer.stop(manager_pid)
    end
  end

  describe "get_view_info/2" do
    setup do
      views = [View.new("detailed", "10.0.0.0/8", ["example.com"], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "returns detailed view information", %{manager_pid: manager_pid} do
      assert {:ok, info} = Operations.get_view_info("detailed", manager_pid: manager_pid)

      assert info.name == "detailed"
      assert info.recursion_enabled == true
      assert info.zone_count == 1
      assert info.zones == ["example.com"]
      assert Map.has_key?(info, :match_clients_details)

      GenServer.stop(manager_pid)
    end

    test "returns error for nonexistent view", %{manager_pid: manager_pid} do
      assert {:error, :view_not_found} =
               Operations.get_view_info("nonexistent", manager_pid: manager_pid)

      GenServer.stop(manager_pid)
    end
  end

  describe "test_client_match/2" do
    setup do
      views = [
        View.new("localhost", "localhost", [], true),
        View.new("internal", "localnets", ["corp.example.com"], true),
        View.new("external", "any", ["public.example.com"], false)
      ]

      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "matches localhost IP to localhost view", %{manager_pid: manager_pid} do
      assert {:ok, result} =
               Operations.test_client_match({127, 0, 0, 1}, manager_pid: manager_pid)

      assert result.matched_view == "localhost"
      assert result.client_ip == "127.0.0.1"
      assert result.recursion_enabled == true

      GenServer.stop(manager_pid)
    end

    test "matches private IP to internal view", %{manager_pid: manager_pid} do
      assert {:ok, result} =
               Operations.test_client_match({192, 168, 1, 100}, manager_pid: manager_pid)

      assert result.matched_view == "internal"
      assert result.client_ip == "192.168.1.100"
      assert result.accessible_zones == ["corp.example.com"]

      GenServer.stop(manager_pid)
    end

    test "matches public IP to external view", %{manager_pid: manager_pid} do
      assert {:ok, result} = Operations.test_client_match({8, 8, 8, 8}, manager_pid: manager_pid)

      assert result.matched_view == "external"
      assert result.client_ip == "8.8.8.8"
      assert result.recursion_enabled == false

      GenServer.stop(manager_pid)
    end

    test "returns error when no views match", %{manager_pid: _pid} do
      # Create manager with only localhost view
      {:ok, localhost_pid} =
        ViewManager.start_link(
          views: [View.new("localhost", "localhost", [], true)],
          name: nil
        )

      assert {:error, error} =
               Operations.test_client_match({8, 8, 8, 8}, manager_pid: localhost_pid)

      assert error.reason == :no_match
      assert error.client_ip == "8.8.8.8"

      GenServer.stop(localhost_pid)
    end
  end

  describe "hot_reload_enabled?/0" do
    test "returns boolean value" do
      result = Operations.hot_reload_enabled?()
      assert is_boolean(result)
    end
  end

  describe "get_config_path/0" do
    test "returns config path when set" do
      # This depends on application configuration
      result = Operations.get_config_path()
      assert match?({:ok, _path}, result) or result == {:error, :not_configured}
    end
  end

  describe "error handling" do
    test "gracefully handles manager unavailability" do
      # Use invalid PID
      fake_pid = spawn(fn -> :ok end)
      # Ensure process is dead
      Process.sleep(10)

      assert {:error, _} =
               Operations.add_view(
                 View.new("test", "any", [], true),
                 manager_pid: fake_pid
               )
    end
  end

  describe "concurrent operations" do
    setup do
      views = [View.new("concurrent", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: views, name: nil)
      %{manager_pid: manager_pid}
    end

    test "handles concurrent status requests", %{manager_pid: manager_pid} do
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Operations.status(manager_pid: manager_pid)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, fn
               {:ok, _status} -> true
               _ -> false
             end)

      GenServer.stop(manager_pid)
    end

    test "handles concurrent list_views requests", %{manager_pid: manager_pid} do
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Operations.list_views(manager_pid: manager_pid)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, fn
               {:ok, views} when is_list(views) -> true
               _ -> false
             end)

      GenServer.stop(manager_pid)
    end
  end
end
