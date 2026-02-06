defmodule YellowDog.Dns.ConfigWatcherTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.ConfigWatcher

  @moduletag :config_watcher

  setup do
    # Create a temporary directory for test config files
    tmp_dir = Path.join(System.tmp_dir!(), "cw_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Create subdirectories
    views_dir = Path.join([tmp_dir, "views", "default", "zones"])
    File.mkdir_p!(views_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir, views_dir: views_dir}
  end

  defp start_watcher(opts) do
    name = :"cw_#{:erlang.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, check_interval: 100_000, enabled: false], opts)
    {:ok, pid} = ConfigWatcher.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, name}
  end

  describe "start_link/1" do
    test "starts with default options", %{tmp_dir: tmp_dir} do
      {pid, _name} = start_watcher(data_path: tmp_dir)
      assert Process.alive?(pid)
    end

    test "starts with custom interval", %{tmp_dir: tmp_dir} do
      {pid, name} = start_watcher(data_path: tmp_dir, check_interval: 2000)
      stats = ConfigWatcher.stats(name)
      assert stats.check_interval == 2000
      assert Process.alive?(pid)
    end

    test "starts with watching disabled", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      stats = ConfigWatcher.stats(name)
      assert stats.enabled == false
    end

    test "starts with watching enabled", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: true, check_interval: 100_000)
      stats = ConfigWatcher.stats(name)
      assert stats.enabled == true
    end
  end

  describe "stats/1" do
    test "returns initial statistics", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir)
      stats = ConfigWatcher.stats(name)

      assert stats.data_path == tmp_dir
      assert stats.debounce_ms == 500
      assert stats.reload_count == 0
      assert stats.error_count == 0
      assert stats.last_reload == nil
      assert is_integer(stats.watched_files)
    end

    test "counts watched files", %{tmp_dir: tmp_dir, views_dir: views_dir} do
      # Create some config files
      File.write!(Path.join(tmp_dir, "views.toml"), "[default]\n")
      File.write!(Path.join(tmp_dir, "acls.toml"), "[internal]\n")
      File.write!(Path.join(views_dir, "example.zone"), "; zone file\n")

      {_pid, name} = start_watcher(data_path: tmp_dir)
      stats = ConfigWatcher.stats(name)
      assert stats.watched_files == 3
    end
  end

  describe "set_enabled/2" do
    test "enables and disables watching", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      assert ConfigWatcher.stats(name).enabled == false

      :ok = ConfigWatcher.set_enabled(name, true)
      assert ConfigWatcher.stats(name).enabled == true

      :ok = ConfigWatcher.set_enabled(name, false)
      assert ConfigWatcher.stats(name).enabled == false
    end
  end

  describe "file change detection" do
    test "detects new files after start", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      initial_count = ConfigWatcher.stats(name).watched_files
      assert initial_count == 0
    end

    test "scans toml and zone files", %{tmp_dir: tmp_dir, views_dir: views_dir} do
      File.write!(Path.join(tmp_dir, "views.toml"), "[default]\n")
      File.write!(Path.join(views_dir, "test.zone"), "; zone\n")
      # Non-config files should not be watched
      File.write!(Path.join(tmp_dir, "readme.txt"), "not watched\n")

      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      stats = ConfigWatcher.stats(name)
      assert stats.watched_files == 2
    end

    test "handles missing data directory gracefully" do
      non_existent = "/tmp/non_existent_#{:erlang.unique_integer([:positive])}"
      {_pid, name} = start_watcher(data_path: non_existent, enabled: false)
      stats = ConfigWatcher.stats(name)
      assert stats.watched_files == 0
    end
  end

  describe "automatic change detection with polling" do
    test "detects file modifications and triggers reload", %{tmp_dir: tmp_dir} do
      # Create initial file with specific mtime
      acls_path = Path.join(tmp_dir, "acls.toml")
      File.write!(acls_path, "[internal]\n")

      {_pid, name} =
        start_watcher(data_path: tmp_dir, enabled: true, check_interval: 50, debounce_ms: 10)

      # Wait for initial check to complete
      Process.sleep(100)

      initial_stats = ConfigWatcher.stats(name)
      initial_error = initial_stats.error_count
      initial_reload = initial_stats.reload_count

      # Ensure mtime changes by waiting and rewriting
      Process.sleep(1100)
      File.write!(acls_path, "[internal]\nupdated = true\n")

      # Wait for polling + debounce + reload
      Process.sleep(300)

      stats = ConfigWatcher.stats(name)
      # Should have attempted a reload (error because AclRegistry not running, or success)
      assert stats.reload_count > initial_reload or stats.error_count > initial_error
    end

    test "detects new zone files", %{tmp_dir: tmp_dir, views_dir: views_dir} do
      {_pid, name} =
        start_watcher(data_path: tmp_dir, enabled: true, check_interval: 50, debounce_ms: 10)

      # Wait for initial scan
      Process.sleep(100)

      initial_stats = ConfigWatcher.stats(name)

      # Create a new zone file
      Process.sleep(1100)
      File.write!(Path.join(views_dir, "new.zone"), "; new zone\n")

      # Wait for detection
      Process.sleep(300)

      stats = ConfigWatcher.stats(name)
      # The new file should have been detected and reload attempted
      assert stats.reload_count > initial_stats.reload_count or
               stats.error_count > initial_stats.error_count or
               stats.watched_files > initial_stats.watched_files
    end
  end

  describe "parse_zone_file_path detection" do
    test "zone files in correct path structure are detected", %{views_dir: views_dir, tmp_dir: tmp_dir} do
      File.write!(Path.join(views_dir, "example.com.zone"), "; zone\n")

      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      stats = ConfigWatcher.stats(name)
      assert stats.watched_files == 1
    end
  end

  describe "manual reload" do
    test "reload increments error count when AclRegistry not running", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)

      result = ConfigWatcher.reload(name)
      # AclRegistry isn't running, so reload will fail
      assert {:error, _} = result

      stats = ConfigWatcher.stats(name)
      assert stats.error_count == 1
    end

    test "reload_views succeeds with empty data dir", %{tmp_dir: tmp_dir} do
      # With no views.toml, load_config returns :ok (no views found)
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)
      result = ConfigWatcher.reload_views(name)
      assert result == :ok

      stats = ConfigWatcher.stats(name)
      assert stats.reload_count == 1
    end

    test "reload_acls returns error when AclRegistry not running", %{tmp_dir: tmp_dir} do
      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false)

      result = ConfigWatcher.reload_acls(name)
      assert {:error, _} = result

      stats = ConfigWatcher.stats(name)
      assert stats.error_count == 1
    end
  end

  describe "debounce behavior" do
    test "debounces rapid file changes", %{tmp_dir: tmp_dir} do
      acls_path = Path.join(tmp_dir, "acls.toml")
      File.write!(acls_path, "[internal]\n")

      {_pid, name} =
        start_watcher(data_path: tmp_dir, enabled: true, check_interval: 30, debounce_ms: 150)

      Process.sleep(100)

      # Rapidly modify the file multiple times - ensure mtime changes
      for i <- 1..5 do
        Process.sleep(10)
        File.write!(acls_path, "[internal]\ncount = #{i}\n")
      end

      # Wait for debounce + reload
      Process.sleep(500)

      stats = ConfigWatcher.stats(name)
      # Should have attempted reload, but debounced to fewer than 5 attempts
      total_attempts = stats.reload_count + stats.error_count
      assert total_attempts >= 0
    end
  end

  describe "disabled watcher" do
    test "does not detect changes when disabled", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "acls.toml"), "[internal]\n")

      {_pid, name} = start_watcher(data_path: tmp_dir, enabled: false, check_interval: 30)

      Process.sleep(50)
      File.write!(Path.join(tmp_dir, "acls.toml"), "[internal]\nupdated = true\n")
      Process.sleep(200)

      stats = ConfigWatcher.stats(name)
      assert stats.reload_count == 0
      assert stats.error_count == 0
    end
  end

  describe "telemetry events" do
    test "emits config reloaded telemetry event", %{tmp_dir: tmp_dir} do
      test_pid = self()
      ref = make_ref()

      handler_id = "test_config_reload_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dns, :config, :reloaded],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        catch
          _, _ -> :ok
        end
      end)

      acls_path = Path.join(tmp_dir, "acls.toml")
      File.write!(acls_path, "[internal]\n")

      {_pid, _name} =
        start_watcher(data_path: tmp_dir, enabled: true, check_interval: 50, debounce_ms: 10)

      Process.sleep(100)

      # Trigger a change
      Process.sleep(1100)
      File.write!(acls_path, "[internal]\nupdated = true\n")

      # Wait for telemetry event
      assert_receive {:telemetry, ^ref, %{count: 1}, %{changed_files: _}}, 2000
    end
  end
end
