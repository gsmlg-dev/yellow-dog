defmodule YellowDog.Dns.View.ConfigWatcherTest do
  # File system operations require sequential execution
  use ExUnit.Case, async: false

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ConfigWatcher
  alias YellowDog.Dns.View.Config, as: ViewConfig

  @test_config_dir "/tmp/yellow_dog_config_watcher_test"

  setup do
    # Create test directory
    File.mkdir_p!(@test_config_dir)

    on_exit(fn ->
      # Cleanup test directory
      File.rm_rf(@test_config_dir)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts with valid configuration path and callback" do
      config_path = Path.join(@test_config_dir, "test1.toml")
      File.write!(config_path, "[[view]]\nname = \"test\"\n")

      reload_count = :counters.new(1, [:atomics])

      opts = [
        config_path: config_path,
        reload_callback: fn _views ->
          :counters.add(reload_count, 1, 1)
          :ok
        end,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "requires either handler_pid or reload_callback" do
      config_path = Path.join(@test_config_dir, "test2.toml")
      File.write!(config_path, "[[view]]\nname = \"test\"\n")

      opts = [config_path: config_path, name: nil]

      # start_link will crash with ArgumentError without handler_pid or reload_callback
      # The simplest test is just to verify it doesn't succeed
      # We use Process.flag to trap exits so the test doesn't crash
      Process.flag(:trap_exit, true)

      # This will return an error tuple or cause an exit
      result = ConfigWatcher.start_link(opts)

      # Verify it's not a success
      refute match?({:ok, _pid}, result)
    end

    test "can be started with a custom name" do
      config_path = Path.join(@test_config_dir, "test3.toml")
      File.write!(config_path, "[[view]]\nname = \"test\"\n")

      opts = [
        config_path: config_path,
        reload_callback: fn _views -> :ok end,
        name: :test_watcher
      ]

      {:ok, _pid} = ConfigWatcher.start_link(opts)
      assert Process.whereis(:test_watcher) != nil

      GenServer.stop(:test_watcher)
    end
  end

  describe "reload/1" do
    setup do
      config_path = Path.join(@test_config_dir, "reload_test.toml")

      File.write!(config_path, """
      [[view]]
      name = "initial"
      match_clients = "any"
      zones = []
      """)

      reload_count = :counters.new(1, [:atomics])
      last_views = :atomics.new(1, [])

      reload_callback = fn views ->
        :counters.add(reload_count, 1, 1)
        # Store view count (can't store actual views in atomics, but count works for testing)
        :atomics.put(last_views, 1, length(views))
        :ok
      end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        debounce_ms: 50,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      %{pid: pid, config_path: config_path, reload_count: reload_count, last_views: last_views}
    end

    test "manually triggers a reload", %{pid: pid, reload_count: reload_count} do
      initial_count = :counters.get(reload_count, 1)

      assert :ok = ConfigWatcher.reload(pid)

      # Wait a bit for reload to complete
      Process.sleep(100)

      new_count = :counters.get(reload_count, 1)
      assert new_count == initial_count + 1
    end

    test "returns error if config file is invalid", %{config_path: config_path} do
      # Create invalid TOML
      File.write!(config_path, "[[view]\ninvalid toml")

      reload_callback = fn _views -> :ok end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      assert {:error, _reason} = ConfigWatcher.reload(pid)

      GenServer.stop(pid)
    end

    test "calls reload callback with parsed views", %{
      pid: pid,
      config_path: config_path,
      last_views: last_views
    } do
      # Update config with 2 views
      File.write!(config_path, """
      [[view]]
      name = "view1"
      match_clients = "any"

      [[view]]
      name = "view2"
      match_clients = "localhost"
      """)

      ConfigWatcher.reload(pid)
      Process.sleep(100)

      # Should have 2 views
      assert :atomics.get(last_views, 1) == 2
    end
  end

  describe "status/1" do
    setup do
      config_path = Path.join(@test_config_dir, "status_test.toml")
      File.write!(config_path, "[[view]]\nname = \"test\"\n")

      opts = [
        config_path: config_path,
        reload_callback: fn _views -> :ok end,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)
      %{pid: pid, config_path: config_path}
    end

    test "returns status map", %{pid: pid} do
      status = ConfigWatcher.status(pid)

      assert is_map(status)
      assert Map.has_key?(status, :config_path)
      assert Map.has_key?(status, :watching)
      assert Map.has_key?(status, :last_reload)
      assert Map.has_key?(status, :reload_count)
      assert Map.has_key?(status, :error_count)
    end

    test "shows watching as true initially", %{pid: pid} do
      status = ConfigWatcher.status(pid)
      assert status.watching == true
    end

    test "tracks successful reload count", %{pid: pid} do
      initial_status = ConfigWatcher.status(pid)
      assert initial_status.reload_count == 0

      ConfigWatcher.reload(pid)
      Process.sleep(100)

      new_status = ConfigWatcher.status(pid)
      assert new_status.reload_count == 1
    end

    test "tracks error count on failed reloads", %{pid: pid, config_path: config_path} do
      initial_status = ConfigWatcher.status(pid)
      assert initial_status.error_count == 0

      # Make config invalid
      File.write!(config_path, "invalid toml")

      ConfigWatcher.reload(pid)
      Process.sleep(100)

      new_status = ConfigWatcher.status(pid)
      assert new_status.error_count == 1
    end
  end

  describe "file watching" do
    @tag :file_watching
    test "detects file modifications" do
      # Ensure directory exists
      File.mkdir_p!(@test_config_dir)

      config_path = Path.join(@test_config_dir, "watch_test.toml")

      File.write!(config_path, """
      [[view]]
      name = "original"
      match_clients = "any"
      """)

      reload_count = :counters.new(1, [:atomics])

      reload_callback = fn _views ->
        :counters.add(reload_count, 1, 1)
        :ok
      end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        debounce_ms: 100,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      # Give file watcher time to start
      Process.sleep(100)

      initial_count = :counters.get(reload_count, 1)

      # Modify the file
      File.write!(config_path, """
      [[view]]
      name = "modified"
      match_clients = "localhost"
      """)

      # Wait for debounce + processing
      Process.sleep(500)

      new_count = :counters.get(reload_count, 1)
      assert new_count == initial_count + 1

      GenServer.stop(pid)
    end

    @tag :file_watching
    test "debounces rapid file changes" do
      # Ensure directory exists
      File.mkdir_p!(@test_config_dir)

      config_path = Path.join(@test_config_dir, "debounce_test.toml")

      File.write!(config_path, """
      [[view]]
      name = "test"
      match_clients = "any"
      """)

      reload_count = :counters.new(1, [:atomics])

      reload_callback = fn _views ->
        :counters.add(reload_count, 1, 1)
        :ok
      end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        debounce_ms: 200,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      # Give file watcher time to start
      Process.sleep(100)

      initial_count = :counters.get(reload_count, 1)

      # Rapid modifications within debounce window
      for i <- 1..5 do
        File.write!(config_path, """
        [[view]]
        name = "test#{i}"
        match_clients = "any"
        """)

        Process.sleep(50)
      end

      # Wait for final debounce to trigger
      Process.sleep(400)

      new_count = :counters.get(reload_count, 1)

      # Should only reload once (debounced)
      assert new_count == initial_count + 1

      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "handles missing config file gracefully" do
      config_path = Path.join(@test_config_dir, "nonexistent.toml")

      reload_callback = fn _views -> :ok end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      # Manual reload should return error
      assert {:error, {:file_read_error, :enoent}} = ConfigWatcher.reload(pid)

      GenServer.stop(pid)
    end

    test "handles callback errors gracefully" do
      config_path = Path.join(@test_config_dir, "callback_error.toml")

      File.write!(config_path, """
      [[view]]
      name = "test"
      match_clients = "any"
      """)

      reload_callback = fn _views ->
        {:error, :callback_failed}
      end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      # Reload should propagate callback error
      assert {:error, :callback_failed} = ConfigWatcher.reload(pid)

      # Error count should increment
      status = ConfigWatcher.status(pid)
      assert status.error_count == 1

      GenServer.stop(pid)
    end

    test "handles invalid TOML syntax" do
      config_path = Path.join(@test_config_dir, "invalid_syntax.toml")

      File.write!(config_path, "[[view]\ninvalid syntax here")

      reload_callback = fn _views -> :ok end

      opts = [
        config_path: config_path,
        reload_callback: reload_callback,
        name: nil
      ]

      {:ok, pid} = ConfigWatcher.start_link(opts)

      assert {:error, {:toml_parse_error, _}} = ConfigWatcher.reload(pid)

      status = ConfigWatcher.status(pid)
      assert status.error_count == 1

      GenServer.stop(pid)
    end
  end

  describe "integration with View.Manager" do
    test "successfully reloads views into Manager" do
      config_path = Path.join(@test_config_dir, "manager_integration.toml")

      File.write!(config_path, """
      [[view]]
      name = "internal"
      match_clients = "localnets"
      zones = ["corp.example.com"]

      [[view]]
      name = "external"
      match_clients = "any"
      zones = ["public.example.com"]
      """)

      # Start Manager
      {:ok, manager_pid} = View.Manager.start_link(name: nil)

      # Start ConfigWatcher with Manager callback
      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          View.Manager.update_views(manager_pid, views)
        end,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Trigger reload
      assert :ok = ConfigWatcher.reload(watcher_pid)
      Process.sleep(100)

      # Verify views were loaded into Manager
      views = View.Manager.get_views(manager_pid)
      assert length(views) == 2
      assert Enum.any?(views, &(&1.name == "internal"))
      assert Enum.any?(views, &(&1.name == "external"))

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end

    test "Manager rejects invalid views from ConfigWatcher" do
      config_path = Path.join(@test_config_dir, "manager_invalid.toml")

      # Create config with duplicate view names
      File.write!(config_path, """
      [[view]]
      name = "duplicate"
      match_clients = "any"

      [[view]]
      name = "duplicate"
      match_clients = "localhost"
      """)

      {:ok, manager_pid} = View.Manager.start_link(name: nil)

      opts = [
        config_path: config_path,
        reload_callback: fn views ->
          View.Manager.update_views(manager_pid, views)
        end,
        name: nil
      ]

      {:ok, watcher_pid} = ConfigWatcher.start_link(opts)

      # Reload should fail due to Manager validation
      assert {:error, _} = ConfigWatcher.reload(watcher_pid)

      # Manager should have no views
      assert View.Manager.get_views(manager_pid) == []

      GenServer.stop(watcher_pid)
      GenServer.stop(manager_pid)
    end
  end
end
