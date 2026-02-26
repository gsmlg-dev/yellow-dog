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

    test "accepts lowercase record types in intercept rules" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "lowercase_type_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "*.local.dev"
      type = "a"
      value = "127.0.0.1"
      ttl = 300

      [[resolved.intercept]]
      match = "*.local.dev"
      type = "aaaa"
      value = "::1"
      ttl = 300
      """)

      config = Config.load(path)
      assert length(config.intercept_rules) == 2
      assert Enum.at(config.intercept_rules, 0).type == :a
      assert Enum.at(config.intercept_rules, 1).type == :aaaa
    end

    test "accepts mixed-case record types" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "mixedcase_type_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "test.local"
      type = "Cname"
      value = "other.local"
      ttl = 60
      """)

      config = Config.load(path)
      assert Enum.at(config.intercept_rules, 0).type == :cname
    end

    test "raises on wildcard-only match pattern" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "wildcard_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "*"
      type = "a"
      value = "0.0.0.0"
      """)

      assert_raise ArgumentError, ~r/invalid match pattern/, fn ->
        Config.load(path)
      end
    end

    test "raises on empty match pattern" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "empty_match_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = ""
      type = "a"
      value = "0.0.0.0"
      """)

      assert_raise ArgumentError, ~r/invalid match pattern/, fn ->
        Config.load(path)
      end
    end

    test "raises on bare suffix wildcard pattern" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bare_suffix_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "*."
      type = "a"
      value = "0.0.0.0"
      """)

      assert_raise ArgumentError, ~r/invalid match pattern/, fn ->
        Config.load(path)
      end
    end

    test "raises on unsupported record type" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_type_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "test.local"
      type = "PTR"
      value = "1.0.0.127.in-addr.arpa"
      ttl = 300
      """)

      assert_raise ArgumentError, ~r/unsupported record type/, fn ->
        Config.load(path)
      end
    end
  end

  describe "prefix match pattern" do
    test "parses prefix pattern from TOML" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "prefix_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "dev-*"
      type = "a"
      value = "10.0.0.1"
      ttl = 120
      """)

      config = Config.load(path)
      assert length(config.intercept_rules) == 1
      [rule] = config.intercept_rules
      assert rule.match == {:prefix, "dev-"}
      assert rule.type == :a
      assert rule.ttl == 120
    end

    test "prefix pattern is case-normalized" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "prefix_case_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "DEV-*"
      type = "a"
      value = "10.0.0.1"
      """)

      config = Config.load(path)
      [rule] = config.intercept_rules
      assert rule.match == {:prefix, "dev-"}
    end
  end

  describe "MX/SRV/TXT intercept rule types" do
    test "parses MX intercept rule" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "mx_rule_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "example.local"
      type = "MX"
      value = "10 mail.example.local"
      ttl = 600
      """)

      config = Config.load(path)
      [rule] = config.intercept_rules
      assert rule.type == :mx
      assert rule.value == "10 mail.example.local"
      assert rule.ttl == 600
    end

    test "parses SRV intercept rule" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "srv_rule_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "_http._tcp.local"
      type = "srv"
      value = "10 20 8080 web.local"
      ttl = 300
      """)

      config = Config.load(path)
      [rule] = config.intercept_rules
      assert rule.type == :srv
      assert rule.value == "10 20 8080 web.local"
    end

    test "parses TXT intercept rule" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "txt_rule_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "info.local"
      type = "TXT"
      value = "v=spf1 include:example.com ~all"
      """)

      config = Config.load(path)
      [rule] = config.intercept_rules
      assert rule.type == :txt
      assert rule.value == "v=spf1 include:example.com ~all"
      # Default TTL
      assert rule.ttl == 300
    end
  end

  describe "config edge cases" do
    test "duplicate upstreams are preserved" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "dup_upstream_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8", "8.8.8.8", "1.1.1.1"]
      """)

      config = Config.load(path)
      assert length(config.upstreams) == 3
    end

    test "all-zeros listen address (bind all interfaces)" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bind_all_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "0.0.0.0"
      port = 5353
      upstreams = ["8.8.8.8"]
      upstream_timeout_ms = 5000
      upstream_failure_threshold = 5
      """)

      config = Config.load(path)
      assert config.listen == {0, 0, 0, 0}
      assert config.port == 5353
      assert config.upstream_timeout_ms == 5000
      assert config.upstream_failure_threshold == 5
    end
  end

  describe "config reload telemetry" do
    test "emits telemetry on successful reload" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "reload_tel_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 5353
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)
      start_supervised!({Config, config})

      ref = make_ref()
      handler_id = "test-config-reload-#{inspect(ref)}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :resolved, :config, :reload],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:config_reload, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Update config file and trigger reload
      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 6363
      upstreams = ["1.1.1.1"]
      """)

      pid = Process.whereis(Config)
      send(pid, {:file_event, nil, {path, [:modified]}})
      Process.sleep(50)

      assert_receive {:config_reload, [:yellow_dog, :resolved, :config, :reload], %{},
                      %{path: ^path}}

      assert Config.get().port == 6363
    end
  end

  describe "IPv6 config parsing" do
    test "accepts IPv6 listen address" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "ipv6_listen_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "::1"
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)
      assert config.listen == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "accepts IPv6 upstream addresses" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "ipv6_upstream_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["2001:4860:4860::8888", "2001:4860:4860::8844"]
      """)

      config = Config.load(path)
      assert length(config.upstreams) == 2
      assert {8193, 18528, 18528, 0, 0, 0, 0, 34952} in config.upstreams
      assert {8193, 18528, 18528, 0, 0, 0, 0, 34884} in config.upstreams
    end

    test "accepts mixed IPv4 and IPv6 upstreams" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "mixed_ip_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8", "2001:4860:4860::8888"]
      """)

      config = Config.load(path)
      assert length(config.upstreams) == 2
      assert {8, 8, 8, 8} in config.upstreams
      assert {8193, 18528, 18528, 0, 0, 0, 0, 34952} in config.upstreams
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

  describe "intercept rule missing required fields" do
    test "raises on missing 'match' field" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "no_match_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      type = "a"
      value = "10.0.0.1"
      """)

      assert_raise ArgumentError, ~r/missing required fields.*match/, fn ->
        Config.load(path)
      end
    end

    test "raises on missing 'type' field" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "no_type_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "test.local"
      value = "10.0.0.1"
      """)

      assert_raise ArgumentError, ~r/missing required fields.*type/, fn ->
        Config.load(path)
      end
    end

    test "raises on missing 'value' field" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "no_value_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "test.local"
      type = "a"
      """)

      assert_raise ArgumentError, ~r/missing required fields.*value/, fn ->
        Config.load(path)
      end
    end

    test "uses default TTL when 'ttl' field is omitted" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "no_ttl_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [[resolved.intercept]]
      match = "test.local"
      type = "a"
      value = "10.0.0.1"
      """)

      config = Config.load(path)
      [rule] = config.intercept_rules
      assert rule.ttl == 300
    end
  end

  describe "validate_config!/1 boundary checks" do
    test "raises on invalid port (negative)" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_port_neg_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = -1
      upstreams = ["8.8.8.8"]
      """)

      assert_raise ArgumentError, ~r/port must be 0\.\.65535/, fn ->
        Config.load(path)
      end
    end

    test "raises on invalid port (too high)" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_port_high_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      port = 70000
      upstreams = ["8.8.8.8"]
      """)

      assert_raise ArgumentError, ~r/port must be 0\.\.65535/, fn ->
        Config.load(path)
      end
    end

    test "raises on zero upstream_timeout_ms" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_timeout_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]
      upstream_timeout_ms = 0
      """)

      assert_raise ArgumentError, ~r/upstream_timeout_ms must be positive/, fn ->
        Config.load(path)
      end
    end

    test "raises on zero upstream_failure_threshold" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_threshold_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]
      upstream_failure_threshold = 0
      """)

      assert_raise ArgumentError, ~r/upstream_failure_threshold must be >= 1/, fn ->
        Config.load(path)
      end
    end

    test "raises when cache min_ttl_s > max_ttl_s" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_cache_ttl_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.cache]
      min_ttl_s = 1000
      max_ttl_s = 100
      """)

      assert_raise ArgumentError, ~r/min_ttl_s.*must be <= max_ttl_s/, fn ->
        Config.load(path)
      end
    end

    test "raises when cache max_entries is 0" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_cache_entries_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.cache]
      max_entries = 0
      """)

      assert_raise ArgumentError, ~r/cache max_entries must be positive/, fn ->
        Config.load(path)
      end
    end

    test "raises when reconnect_base_s > reconnect_max_s" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_reconnect_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.discovery.websocket]
      reconnect_base_s = 120
      reconnect_max_s = 30
      """)

      assert_raise ArgumentError, ~r/reconnect_base_s.*must be <= reconnect_max_s/, fn ->
        Config.load(path)
      end
    end

    test "accepts valid boundary values (port 0, port 65535)" do
      tmp_dir = System.tmp_dir!()
      path0 = Path.join(tmp_dir, "port_zero_#{System.unique_integer([:positive])}.toml")
      path65535 = Path.join(tmp_dir, "port_max_#{System.unique_integer([:positive])}.toml")

      on_exit(fn ->
        File.rm(path0)
        File.rm(path65535)
      end)

      File.write!(path0, """
      [resolved]
      listen = "127.0.0.1"
      port = 0
      upstreams = ["8.8.8.8"]
      """)

      config0 = Config.load(path0)
      assert config0.port == 0

      File.write!(path65535, """
      [resolved]
      listen = "127.0.0.1"
      port = 65535
      upstreams = ["8.8.8.8"]
      """)

      config65535 = Config.load(path65535)
      assert config65535.port == 65535
    end

    test "accepts equal min_ttl_s and max_ttl_s" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "equal_ttl_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.cache]
      min_ttl_s = 60
      max_ttl_s = 60
      """)

      config = Config.load(path)
      assert config.cache.min_ttl_s == 60
      assert config.cache.max_ttl_s == 60
    end

    test "raises on negative upstream_timeout_ms" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "neg_timeout_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]
      upstream_timeout_ms = -500
      """)

      assert_raise ArgumentError, ~r/upstream_timeout_ms must be positive/, fn ->
        Config.load(path)
      end
    end

    test "raises on negative upstream_failure_threshold" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "neg_threshold_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]
      upstream_failure_threshold = -1
      """)

      assert_raise ArgumentError, ~r/upstream_failure_threshold must be >= 1/, fn ->
        Config.load(path)
      end
    end

    test "raises on negative cache max_entries" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "neg_entries_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.cache]
      max_entries = -100
      """)

      assert_raise ArgumentError, ~r/cache max_entries must be positive/, fn ->
        Config.load(path)
      end
    end

    test "accepts equal reconnect_base_s and reconnect_max_s" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "equal_reconnect_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]

      [resolved.discovery.websocket]
      reconnect_base_s = 60
      reconnect_max_s = 60
      """)

      config = Config.load(path)
      assert config.discovery.websocket.reconnect_base_s == 60
      assert config.discovery.websocket.reconnect_max_s == 60
    end

    test "accepts large timeout values" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "large_timeout_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      listen = "127.0.0.1"
      upstreams = ["8.8.8.8"]
      upstream_timeout_ms = 60000
      upstream_failure_threshold = 100
      """)

      config = Config.load(path)
      assert config.upstream_timeout_ms == 60000
      assert config.upstream_failure_threshold == 100
    end
  end

  describe "reload_failed telemetry" do
    test "emits reload_failed telemetry on invalid config file" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "reload_fail_tel_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      [resolved]
      port = 5353
      upstreams = ["8.8.8.8"]
      """)

      config = Config.load(path)
      start_supervised!({Config, config})

      test_pid = self()
      ref = make_ref()
      handler_id = "test-reload-failed-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :resolved, :config, :reload_failed],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:reload_failed, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Corrupt the file to trigger reload failure
      File.write!(path, "invalid toml {{{{")

      pid = Process.whereis(Config)

      capture_log(fn ->
        send(pid, {:file_event, nil, {path, [:modified]}})
        Process.sleep(50)
      end)

      assert_receive {:reload_failed, metadata}
      assert metadata.path == path
      assert metadata.reason != nil
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
