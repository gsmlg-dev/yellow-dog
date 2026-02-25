defmodule YellowDog.Resolved.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.Config

  @test_config_path Path.join([__DIR__, "..", "..", "config", "resolved.toml"])
                    |> Path.expand()

  describe "load/1" do
    test "loads the default config file" do
      config = Config.load(@test_config_path)

      assert config.listen == {127, 0, 0, 1}
      assert config.port == 53
      assert length(config.upstreams) == 3
      assert config.upstream_timeout_ms == 3000
      assert config.upstream_failure_threshold == 3
    end

    test "parses intercept rules" do
      config = Config.load(@test_config_path)

      assert length(config.intercept_rules) == 4
      [rule1, rule2, rule3, rule4] = config.intercept_rules

      assert rule1.match == {:suffix, "local.dev"}
      assert rule1.type == :a
      assert rule1.value == "127.0.0.1"
      assert rule1.ttl == 300

      assert rule2.match == {:suffix, "local.dev"}
      assert rule2.type == :aaaa

      assert rule3.match == {:exact, "myapp.test"}
      assert rule3.type == :a
      assert rule3.value == "192.168.1.100"

      assert rule4.match == {:exact, "db.internal"}
      assert rule4.type == :cname
    end

    test "parses cache config" do
      config = Config.load(@test_config_path)

      assert config.cache.enabled == true
      assert config.cache.max_entries == 10_000
      assert config.cache.min_ttl_s == 30
      assert config.cache.max_ttl_s == 86_400
      assert config.cache.negative_ttl_s == 60
      assert config.cache.sweep_interval_s == 60
    end

    test "parses discovery config" do
      config = Config.load(@test_config_path)

      assert config.discovery.enabled == true
      assert config.discovery.websocket.heartbeat_interval_s == 30
      assert config.discovery.websocket.reconnect_base_s == 5
      assert config.discovery.websocket.reconnect_max_s == 60
    end

    test "parses upstream IPs" do
      config = Config.load(@test_config_path)

      assert {192, 168, 1, 1} in config.upstreams
      assert {1, 1, 1, 1} in config.upstreams
      assert {8, 8, 8, 8} in config.upstreams
    end

    test "raises on invalid config path" do
      assert_raise RuntimeError, ~r/Failed to load config/, fn ->
        Config.load("/nonexistent/path/config.toml")
      end
    end

    test "config_path is stored in result" do
      config = Config.load(@test_config_path)
      assert config.config_path == @test_config_path
    end
  end

  describe "GenServer client API" do
    setup do
      config = Config.load(@test_config_path)
      start_supervised!({Config, config})
      {:ok, config: config}
    end

    test "get/0 returns the full config", %{config: config} do
      result = Config.get()
      assert result.listen == config.listen
      assert result.port == config.port
      assert result.upstreams == config.upstreams
    end

    test "get_intercept_rules/0 returns only rules", %{config: config} do
      rules = Config.get_intercept_rules()
      assert rules == config.intercept_rules
      assert length(rules) == 4
    end

    test "get_upstreams/0 returns only upstreams", %{config: config} do
      upstreams = Config.get_upstreams()
      assert upstreams == config.upstreams
      assert length(upstreams) == 3
    end
  end

  describe "config defaults" do
    test "uses defaults when TOML sections are missing" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "minimal_resolved_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 5353
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)

      assert config.listen == {127, 0, 0, 1}
      assert config.port == 5353
      assert config.upstreams == [{8, 8, 8, 8}]
      # Defaults
      assert config.upstream_timeout_ms == 3000
      assert config.upstream_failure_threshold == 3
      assert config.intercept_rules == []
      assert config.cache.enabled == true
      assert config.cache.max_entries == 10_000
      assert config.discovery.enabled == true
    end

    test "uses defaults when config is completely empty" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "empty_resolved_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, "")

      config = Config.load(path)

      assert config.listen == {127, 0, 0, 1}
      assert config.port == 53
      assert config.upstreams == [{1, 1, 1, 1}, {8, 8, 8, 8}]
    end
  end

  describe "GenServer handle_info catch-all" do
    setup do
      config = Config.load(@test_config_path)
      start_supervised!({Config, config})
      :ok
    end

    test "ignores unexpected messages" do
      pid = Process.whereis(Config)
      send(pid, :unexpected_message)
      Process.sleep(10)

      assert Process.alive?(pid)
      # Can still serve requests after unknown message
      assert is_list(Config.get_upstreams())
    end
  end

  describe "config validation" do
    test "raises on invalid IP address" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_ip_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "not-an-ip"
      upstreams = ["8.8.8.8"]
      """)

      assert_raise ArgumentError, ~r/invalid IP address/, fn ->
        Config.load(path)
      end
    end

    test "raises on invalid upstream IP" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_upstream_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["999.999.999.999"]
      """)

      assert_raise ArgumentError, ~r/invalid IP address/, fn ->
        Config.load(path)
      end
    end
  end

  describe "hot reload via file event" do
    test "reloads config when toml file changes" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "reload_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      # Write initial config
      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 5353
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)
      start_supervised!({Config, config})

      assert Config.get().port == 5353

      # Simulate a file change event (as if the watcher detected it)
      pid = Process.whereis(Config)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 5454
      upstreams = ["1.1.1.1"]
      """)

      send(pid, {:file_event, nil, {path, [:modified]}})
      Process.sleep(50)

      assert Config.get().port == 5454
      assert Config.get().upstreams == [{1, 1, 1, 1}]
    end

    test "survives reload of invalid config file" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_reload_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      port = 5353
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)
      start_supervised!({Config, config})

      # Make the file invalid
      File.write!(path, "invalid toml {{{{")

      pid = Process.whereis(Config)

      log =
        capture_log(fn ->
          send(pid, {:file_event, nil, {path, [:modified]}})
          Process.sleep(50)
        end)

      assert log =~ "Failed to reload config"

      # Should still be alive with old config
      assert Process.alive?(pid)
      assert Config.get().port == 5353
    end

    test "ignores non-toml file events" do
      config = Config.load(@test_config_path)
      start_supervised!({Config, config})

      pid = Process.whereis(Config)
      original = Config.get()

      send(pid, {:file_event, nil, {"/some/file.json", [:modified]}})
      Process.sleep(10)

      assert Config.get() == original
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      config = Config.load(@test_config_path)
      start_supervised!({Config, config})

      pid = Process.whereis(Config)
      assert Process.alive?(pid)

      stop_supervised!(Config)

      refute Process.alive?(pid)
    end
  end
end
