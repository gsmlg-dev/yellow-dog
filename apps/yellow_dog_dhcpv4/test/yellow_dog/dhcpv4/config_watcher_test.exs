defmodule YellowDog.Dhcpv4.ConfigWatcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.ConfigWatcher

  @moduletag :capture_log

  # Test helper to create a temporary config file
  defp create_temp_config(content \\ "{}") do
    dir = System.tmp_dir!()
    file = Path.join(dir, "test_config_#{:rand.uniform(100_000)}.json")
    File.write!(file, content)
    file
  end

  defp cleanup_file(file) do
    File.rm(file)
  end

  describe "start_link/1" do
    test "starts with valid config file and callback" do
      config_file = create_temp_config()

      try do
        # Use a unique name to avoid conflicts
        result =
          start_supervised!(
            {ConfigWatcher,
             config_file: config_file, reload_callback: fn _config -> :ok end, enabled: true}
          )

        assert is_pid(result)
      after
        cleanup_file(config_file)
      end
    end

    test "starts in disabled state when enabled: false" do
      result =
        start_supervised!(
          {ConfigWatcher,
           config_file: "/some/file.toml", reload_callback: fn _config -> :ok end, enabled: false}
        )

      assert is_pid(result)
      assert ConfigWatcher.status() == %{enabled: false}
    end

    test "starts in disabled state when no config file provided" do
      result =
        start_supervised!({ConfigWatcher, reload_callback: fn _config -> :ok end})

      assert is_pid(result)
      assert ConfigWatcher.status() == %{enabled: false}
    end

    test "starts in disabled state when config file doesn't exist" do
      result =
        start_supervised!(
          {ConfigWatcher,
           config_file: "/nonexistent/path/config.toml", reload_callback: fn _config -> :ok end}
        )

      assert is_pid(result)
      assert ConfigWatcher.status() == %{enabled: false}
    end

    test "fails to start without reload callback when enabled" do
      config_file = create_temp_config()

      # Trap exits so we can test the failure without crashing the test process
      Process.flag(:trap_exit, true)

      try do
        # This should fail because reload_callback is required
        result = ConfigWatcher.start_link(config_file: config_file, enabled: true)
        assert {:error, :no_reload_callback} = result
      after
        Process.flag(:trap_exit, false)
        cleanup_file(config_file)
      end
    end
  end

  describe "status/0" do
    test "returns disabled status when watcher is disabled" do
      start_supervised!(
        {ConfigWatcher, config_file: nil, reload_callback: fn _config -> :ok end, enabled: false}
      )

      assert ConfigWatcher.status() == %{enabled: false}
    end

    test "returns full status when watcher is enabled" do
      config_file = create_temp_config()

      try do
        start_supervised!(
          {ConfigWatcher,
           config_file: config_file, reload_callback: fn _config -> :ok end, debounce_ms: 500}
        )

        status = ConfigWatcher.status()

        assert status.enabled == true
        assert status.config_file == Path.expand(config_file)
        assert status.reload_count == 0
        assert status.last_reload == nil
        assert status.debounce_ms == 500
      after
        cleanup_file(config_file)
      end
    end
  end

  describe "reload/0" do
    test "returns error when watcher is disabled" do
      start_supervised!({ConfigWatcher, enabled: false})

      assert {:error, :watcher_disabled} = ConfigWatcher.reload()
    end

    test "successfully reloads config and calls callback" do
      config_file = create_temp_config(~s({"test": "value"}))
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config_loaded, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        assert :ok = ConfigWatcher.reload()

        assert_receive {:config_loaded, config}
        assert config["test"] == "value"
      after
        cleanup_file(config_file)
      end
    end

    test "increments reload count on successful reload" do
      config_file = create_temp_config()

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: fn _config -> :ok end}
        )

        assert ConfigWatcher.status().reload_count == 0

        :ok = ConfigWatcher.reload()
        assert ConfigWatcher.status().reload_count == 1

        :ok = ConfigWatcher.reload()
        assert ConfigWatcher.status().reload_count == 2
      after
        cleanup_file(config_file)
      end
    end

    test "updates last_reload timestamp on successful reload" do
      config_file = create_temp_config()

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: fn _config -> :ok end}
        )

        assert ConfigWatcher.status().last_reload == nil

        :ok = ConfigWatcher.reload()

        last_reload = ConfigWatcher.status().last_reload
        assert is_integer(last_reload)
        # Should be within last few seconds
        assert System.system_time(:second) - last_reload < 5
      after
        cleanup_file(config_file)
      end
    end

    test "returns error when callback fails" do
      config_file = create_temp_config()

      callback = fn _config ->
        {:error, :callback_failed}
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        assert {:error, :callback_failed} = ConfigWatcher.reload()
        # Reload count should not increment on failure
        assert ConfigWatcher.status().reload_count == 0
      after
        cleanup_file(config_file)
      end
    end

    test "returns error when config file read fails" do
      config_file = create_temp_config()

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: fn _config -> :ok end}
        )

        # Delete the file to cause read failure
        File.rm!(config_file)

        assert {:error, :enoent} = ConfigWatcher.reload()
      after
        # File already deleted
        :ok
      end
    end

    test "parses JSON config correctly" do
      config_content =
        ~s({"pools": [{"name": "default", "range": "192.168.1.100-192.168.1.200"}]})

      config_file = create_temp_config(config_content)
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        assert is_list(config["pools"])
        assert hd(config["pools"])["name"] == "default"
      after
        cleanup_file(config_file)
      end
    end

    test "handles non-JSON content gracefully" do
      config_file = create_temp_config("not valid json content")
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        # Should not fail, just return raw content
        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        assert config.raw == "not valid json content"
      after
        cleanup_file(config_file)
      end
    end
  end

  describe "file watching" do
    test "triggers reload when config file is modified" do
      config_file = create_temp_config(~s({"version": 1}))
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config_loaded, config})
        :ok
      end

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: callback, debounce_ms: 100}
        )

        # Clear any initial messages
        receive do
          _ -> :ok
        after
          50 -> :ok
        end

        # Modify the file
        File.write!(config_file, ~s({"version": 2}))

        # Wait for debounce + processing time
        :timer.sleep(300)

        # Should receive the updated config
        assert_receive {:config_loaded, config}, 1000
        assert config["version"] == 2
      after
        cleanup_file(config_file)
      end
    end

    test "debounces rapid file changes" do
      config_file = create_temp_config(~s({"version": 1}))
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      callback = fn config ->
        :counters.add(call_count, 1, 1)
        send(test_pid, {:config_loaded, config})
        :ok
      end

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: callback, debounce_ms: 200}
        )

        # Make multiple rapid changes
        for i <- 1..5 do
          File.write!(config_file, ~s({"version": #{i}}))
          :timer.sleep(50)
        end

        # Wait for debounce to complete
        :timer.sleep(500)

        # Should only trigger reload once (or at most twice) due to debouncing
        count = :counters.get(call_count, 1)
        assert count <= 2, "Expected at most 2 reloads due to debouncing, got #{count}"
      after
        cleanup_file(config_file)
      end
    end

    test "ignores changes to other files in same directory" do
      dir = System.tmp_dir!()
      config_file = Path.join(dir, "config_#{:rand.uniform(100_000)}.json")
      other_file = Path.join(dir, "other_#{:rand.uniform(100_000)}.json")

      File.write!(config_file, "{}")
      File.write!(other_file, "{}")

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      callback = fn _config ->
        :counters.add(call_count, 1, 1)
        send(test_pid, :reloaded)
        :ok
      end

      try do
        start_supervised!(
          {ConfigWatcher, config_file: config_file, reload_callback: callback, debounce_ms: 100}
        )

        # Modify the other file
        File.write!(other_file, ~s({"other": true}))

        # Wait for potential debounce
        :timer.sleep(300)

        # Should not have triggered reload for other file
        assert :counters.get(call_count, 1) == 0
      after
        cleanup_file(config_file)
        cleanup_file(other_file)
      end
    end
  end

  describe "edge cases" do
    test "handles empty config file" do
      config_file = create_temp_config("")
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        # Empty string is not valid JSON, so should return raw
        assert config.raw == ""
      after
        cleanup_file(config_file)
      end
    end

    test "handles config file with nested JSON" do
      config_content = ~s({
        "pools": [
          {
            "name": "office",
            "subnet": "192.168.1.0/24",
            "ranges": [
              {"start": "192.168.1.100", "end": "192.168.1.200"}
            ],
            "options": {
              "router": "192.168.1.1",
              "dns": ["8.8.8.8", "8.8.4.4"]
            }
          }
        ]
      })

      config_file = create_temp_config(config_content)
      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        pool = hd(config["pools"])
        assert pool["name"] == "office"
        assert pool["options"]["router"] == "192.168.1.1"
        assert pool["options"]["dns"] == ["8.8.8.8", "8.8.4.4"]
      after
        cleanup_file(config_file)
      end
    end

    test "callback exception causes GenServer crash (no built-in exception handling)" do
      # Note: The implementation doesn't wrap callback execution in try/rescue,
      # so exceptions in the callback will crash the GenServer.
      # This test documents the current behavior.
      config_file = create_temp_config()

      callback = fn _config ->
        raise "Intentional error in callback"
      end

      try do
        start_supervised!({ConfigWatcher, config_file: config_file, reload_callback: callback})

        # This will crash the GenServer because exceptions aren't caught
        result =
          try do
            ConfigWatcher.reload()
          catch
            :exit, _ -> {:error, :callback_crashed}
          end

        assert {:error, :callback_crashed} = result
      after
        cleanup_file(config_file)
      end
    end

    test "handles config file path with spaces" do
      dir = System.tmp_dir!()
      file = Path.join(dir, "config with spaces #{:rand.uniform(100_000)}.json")
      File.write!(file, ~s({"spaces": true}))

      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: file, reload_callback: callback})

        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        assert config["spaces"] == true
      after
        File.rm(file)
      end
    end

    test "handles symlinked config file" do
      dir = System.tmp_dir!()
      real_file = Path.join(dir, "real_config_#{:rand.uniform(100_000)}.json")
      link_file = Path.join(dir, "link_config_#{:rand.uniform(100_000)}.json")

      File.write!(real_file, ~s({"symlink": true}))
      File.ln_s!(real_file, link_file)

      test_pid = self()

      callback = fn config ->
        send(test_pid, {:config, config})
        :ok
      end

      try do
        start_supervised!({ConfigWatcher, config_file: link_file, reload_callback: callback})

        :ok = ConfigWatcher.reload()

        assert_receive {:config, config}
        assert config["symlink"] == true
      after
        File.rm(link_file)
        File.rm(real_file)
      end
    end
  end
end
