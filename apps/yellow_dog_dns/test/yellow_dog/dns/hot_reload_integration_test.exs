defmodule YellowDog.Dns.HotReloadIntegrationTest do
  @moduledoc """
  Integration tests for hot-reload system.

  Tests the complete flow: ConfigWatcher → View.Manager → Handler.UDP
  Verifies that configuration changes are propagated through the system
  without requiring restarts.
  """

  # File system operations require sequential execution
  use ExUnit.Case, async: false

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.Manager, as: ViewManager
  alias YellowDog.Dns.View.ConfigWatcher
  alias YellowDog.Dns.Handler.UDP, as: Handler

  @test_config_dir "/tmp/yellow_dog_hot_reload_test"

  setup do
    # Create test directory
    File.mkdir_p!(@test_config_dir)

    on_exit(fn ->
      # Cleanup test directory
      File.rm_rf(@test_config_dir)
    end)

    :ok
  end

  describe "ConfigWatcher → ViewManager integration" do
    test "views are updated in Manager when config file changes" do
      config_path = Path.join(@test_config_dir, "views1.toml")

      # Create initial config
      File.write!(config_path, """
      [[view]]
      name = "initial"
      match_clients = "any"
      zones = []
      """)

      # Start Manager
      {:ok, manager_pid} = ViewManager.start_link(views: [], name: nil)

      # Start ConfigWatcher
      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          ViewManager.update_views(manager_pid, views)
        end,
        debounce_ms: 50,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Trigger initial load
      assert :ok = ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      # Verify initial view loaded
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      assert hd(views).name == "initial"

      # Update config file
      File.write!(config_path, """
      [[view]]
      name = "updated"
      match_clients = "localhost"
      zones = ["example.com"]

      [[view]]
      name = "default"
      match_clients = "any"
      zones = []
      """)

      # Trigger reload
      assert :ok = ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      # Verify views updated in Manager
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 2
      assert Enum.any?(views, &(&1.name == "updated"))
      assert Enum.any?(views, &(&1.name == "default"))

      # Verify view details
      updated_view = Enum.find(views, &(&1.name == "updated"))
      assert View.matches?(updated_view, {127, 0, 0, 1})
      assert View.has_zone?(updated_view, "example.com")

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end

    test "Manager rejects invalid configuration from ConfigWatcher" do
      config_path = Path.join(@test_config_dir, "views2.toml")

      # Create valid initial config
      File.write!(config_path, """
      [[view]]
      name = "valid"
      match_clients = "any"
      zones = []
      """)

      {:ok, manager_pid} = ViewManager.start_link(views: [], name: nil)

      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          ViewManager.update_views(manager_pid, views)
        end,
        debounce_ms: 50,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Load valid config
      ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      assert length(ViewManager.get_views(manager_pid)) == 1

      # Update to invalid config (duplicate names)
      File.write!(config_path, """
      [[view]]
      name = "duplicate"
      match_clients = "any"
      zones = []

      [[view]]
      name = "duplicate"
      match_clients = "localhost"
      zones = []
      """)

      # Reload should fail
      assert {:error, _} = ConfigWatcher.reload(watcher_pid)

      # Original views should be preserved
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      assert hd(views).name == "valid"

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end
  end

  describe "ViewManager → Handler integration" do
    test "Handler uses current views from Manager on each query" do
      # Start Manager with initial view
      initial_views = [View.new("test", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)

      # Simulate Handler state with manager PID
      handler_state = %{
        view_manager_pid: manager_pid,
        mode: :authoritative,
        upstream_servers: [],
        loaded_zones: [],
        stats: %{
          queries: 0,
          cache_hits: 0,
          authoritative: 0,
          recursive: 0,
          forwarded: 0,
          errors: 0,
          view_matches: 0
        }
      }

      # Handler should get views from Manager
      views = ViewManager.get_views(handler_state.view_manager_pid)
      assert length(views) == 1
      assert hd(views).name == "test"

      # Update views in Manager
      new_views = [
        View.new("internal", "localnets", [], true),
        View.new("external", "any", [], false)
      ]

      ViewManager.update_views(manager_pid, new_views)

      # Handler should immediately see new views
      views = ViewManager.get_views(handler_state.view_manager_pid)
      assert length(views) == 2
      assert Enum.any?(views, &(&1.name == "internal"))
      assert Enum.any?(views, &(&1.name == "external"))

      GenServer.stop(manager_pid)
    end

    test "Handler matches clients to correct views after hot-reload" do
      initial_views = [View.new("default", "any", [], true)]
      {:ok, manager_pid} = ViewManager.start_link(views: initial_views, name: nil)

      # Internal IP should match default view initially
      views = ViewManager.get_views(manager_pid)
      {:ok, view} = View.match_client({192, 168, 1, 100}, views)
      assert view.name == "default"

      # Update to add specific view for internal networks
      new_views = [
        View.new("internal", "localnets", ["corp.example.com"], true),
        View.new("external", "any", ["public.example.com"], false)
      ]

      ViewManager.update_views(manager_pid, new_views)

      # Internal IP should now match internal view
      views = ViewManager.get_views(manager_pid)
      {:ok, view} = View.match_client({192, 168, 1, 100}, views)
      assert view.name == "internal"
      assert view.recursion_enabled == true
      assert View.has_zone?(view, "corp.example.com")

      # External IP should match external view
      {:ok, view} = View.match_client({8, 8, 8, 8}, views)
      assert view.name == "external"
      assert view.recursion_enabled == false
      assert View.has_zone?(view, "public.example.com")

      GenServer.stop(manager_pid)
    end
  end

  describe "End-to-end hot-reload" do
    @tag :integration
    test "complete hot-reload flow: file change → ConfigWatcher → Manager → Handler" do
      config_path = Path.join(@test_config_dir, "e2e.toml")

      # Create initial config
      File.write!(config_path, """
      [[view]]
      name = "default"
      match_clients = "any"
      zones = []
      recursion_enabled = true
      """)

      # Start Manager
      {:ok, manager_pid} = ViewManager.start_link(views: [], name: nil)

      # Start ConfigWatcher
      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          ViewManager.update_views(manager_pid, views)
        end,
        debounce_ms: 50,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Load initial config
      ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      # Simulate Handler getting views
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      assert hd(views).name == "default"

      # Simulate DNS query from internal client
      {:ok, matched_view} = View.match_client({192, 168, 1, 10}, views)
      assert matched_view.name == "default"
      assert matched_view.recursion_enabled == true

      # Update configuration to split internal/external
      File.write!(config_path, """
      [[view]]
      name = "internal"
      match_clients = "localnets"
      zones = ["corp.example.com", "internal.net"]
      recursion_enabled = true

      [[view]]
      name = "external"
      match_clients = "any"
      zones = ["public.example.com"]
      recursion_enabled = false
      """)

      # Trigger reload
      ConfigWatcher.reload(watcher_pid)
      Process.sleep(150)

      # Handler immediately sees new configuration
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 2

      # Internal client now matches internal view
      {:ok, matched_view} = View.match_client({192, 168, 1, 10}, views)
      assert matched_view.name == "internal"
      assert matched_view.recursion_enabled == true
      assert View.has_zone?(matched_view, "corp.example.com")

      # External client matches external view
      {:ok, matched_view} = View.match_client({8, 8, 8, 8}, views)
      assert matched_view.name == "external"
      assert matched_view.recursion_enabled == false
      assert View.has_zone?(matched_view, "public.example.com")

      # Get statistics from both components
      manager_stats = ViewManager.stats(manager_pid)
      assert manager_stats.view_count == 2
      assert manager_stats.update_count >= 2

      watcher_status = ConfigWatcher.status(watcher_pid)
      assert watcher_status.watching == true
      assert watcher_status.reload_count >= 2
      assert watcher_status.error_count == 0

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end

    @tag :integration
    test "hot-reload handles rapid manual reload requests" do
      config_path = Path.join(@test_config_dir, "rapid.toml")

      File.write!(config_path, """
      [[view]]
      name = "v1"
      match_clients = "any"
      zones = []
      """)

      {:ok, manager_pid} = ViewManager.start_link(views: [], name: nil)

      reload_count = :counters.new(1, [:atomics])

      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          :counters.add(reload_count, 1, 1)
          ViewManager.update_views(manager_pid, views)
        end,
        debounce_ms: 200,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Initial load
      ConfigWatcher.reload(watcher_pid)
      Process.sleep(50)

      initial_count = :counters.get(reload_count, 1)

      # Rapid manual reloads (immediate, not debounced)
      for i <- 2..6 do
        File.write!(config_path, """
        [[view]]
        name = "v#{i}"
        match_clients = "any"
        zones = []
        """)

        ConfigWatcher.reload(watcher_pid)
        Process.sleep(30)
      end

      # Wait for any pending reloads
      Process.sleep(100)

      # Manual reloads are immediate, so all 5 should have happened
      final_count = :counters.get(reload_count, 1)
      reload_diff = final_count - initial_count

      # Should have all 5 manual reloads
      assert reload_diff == 5

      # Final config should be loaded
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      # Should be one of the later versions
      assert hd(views).name in ["v2", "v3", "v4", "v5", "v6"]

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end
  end

  describe "Error handling and recovery" do
    test "system continues operating after failed reload attempt" do
      config_path = Path.join(@test_config_dir, "recovery.toml")

      # Create valid initial config
      File.write!(config_path, """
      [[view]]
      name = "stable"
      match_clients = "any"
      zones = []
      """)

      {:ok, manager_pid} = ViewManager.start_link(views: [], name: nil)

      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          ViewManager.update_views(manager_pid, views)
        end,
        debounce_ms: 50,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Load valid config
      ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      assert length(ViewManager.get_views(manager_pid)) == 1

      # Attempt to load invalid config
      File.write!(config_path, "[[view]\ninvalid toml syntax")

      assert {:error, _} = ConfigWatcher.reload(watcher_pid)

      # Original views should still be available
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      assert hd(views).name == "stable"

      # Fix config and reload successfully
      File.write!(config_path, """
      [[view]]
      name = "recovered"
      match_clients = "localhost"
      zones = ["example.com"]
      """)

      assert :ok = ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      # New config should be loaded
      views = ViewManager.get_views(manager_pid)
      assert length(views) == 1
      assert hd(views).name == "recovered"

      # Verify watcher tracked both error and recovery
      status = ConfigWatcher.status(watcher_pid)
      assert status.error_count >= 1
      assert status.reload_count >= 2

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end
  end
end
