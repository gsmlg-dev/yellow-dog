defmodule YellowDog.Resolved.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Config

  describe "TOML parsing" do
    test "load/0 returns a valid config map" do
      config = Config.load()

      assert is_map(config)
      assert is_tuple(config.listen)
      assert is_integer(config.port)
      assert is_list(config.upstreams)
      assert is_integer(config.upstream_timeout_ms)
      assert is_integer(config.upstream_failure_threshold)
      assert is_map(config.cache)
      assert is_map(config.discovery)
      assert is_list(config.intercept_rules)
    end

    test "load/0 parses cache config with expected keys" do
      config = Config.load()

      assert Map.has_key?(config.cache, :enabled)
      assert Map.has_key?(config.cache, :max_entries)
      assert Map.has_key?(config.cache, :min_ttl_s)
      assert Map.has_key?(config.cache, :max_ttl_s)
      assert Map.has_key?(config.cache, :negative_ttl_s)
      assert Map.has_key?(config.cache, :sweep_interval_s)
    end

    test "load/0 parses discovery config with expected keys" do
      config = Config.load()

      assert Map.has_key?(config.discovery, :enabled)
      assert Map.has_key?(config.discovery, :websocket)
      assert Map.has_key?(config.discovery.websocket, :heartbeat_interval_s)
      assert Map.has_key?(config.discovery.websocket, :reconnect_base_s)
      assert Map.has_key?(config.discovery.websocket, :reconnect_max_s)
    end

    test "load/0 parses intercept rules from TOML" do
      config = Config.load()

      # The default config/resolved.toml has intercept rules
      assert length(config.intercept_rules) > 0

      for rule <- config.intercept_rules do
        assert Map.has_key?(rule, :match)
        assert Map.has_key?(rule, :type)
        assert Map.has_key?(rule, :value)
        assert Map.has_key?(rule, :ttl)

        # match is a tuple
        assert is_tuple(rule.match)
        {kind, _pattern} = rule.match
        assert kind in [:exact, :suffix, :prefix]
      end
    end

    test "load/0 parses all record types from TOML correctly" do
      config = Config.load()
      rules = config.intercept_rules

      types = Enum.map(rules, & &1.type)

      # Our config has A, AAAA, CNAME, TXT, MX, SRV rules
      assert :a in types
      assert :aaaa in types
      assert :cname in types
      assert :txt in types
      assert :mx in types
      assert :srv in types
    end

    test "load/0 parses wildcard suffix match correctly" do
      config = Config.load()

      suffix_rules =
        Enum.filter(config.intercept_rules, fn rule ->
          match?({:suffix, _}, rule.match)
        end)

      assert length(suffix_rules) > 0

      for rule <- suffix_rules do
        {:suffix, suffix} = rule.match
        # Suffix should not contain the leading "*."
        refute String.starts_with?(suffix, "*.")
      end
    end

    test "load/0 parses exact match correctly" do
      config = Config.load()

      exact_rules =
        Enum.filter(config.intercept_rules, fn rule ->
          match?({:exact, _}, rule.match)
        end)

      assert length(exact_rules) > 0
    end

    test "load/0 parses IP addresses in upstreams" do
      config = Config.load()

      for upstream <- config.upstreams do
        assert is_tuple(upstream)
        assert tuple_size(upstream) in [4, 8]
      end
    end
  end

  describe "Config GenServer" do
    test "get/0 returns current config" do
      config = Config.load()
      start_supervised!({Config, config})

      retrieved = Config.get()
      assert retrieved == config
    end

    test "get/1 returns a specific key" do
      config = Config.load()
      start_supervised!({Config, config})

      assert Config.get(:port) == config.port
      assert Config.get(:upstreams) == config.upstreams
    end

    test "get/1 returns nil for unknown key" do
      config = Config.load()
      start_supervised!({Config, config})

      assert Config.get(:nonexistent) == nil
    end

    test "handles unknown messages gracefully" do
      config = Config.load()
      start_supervised!({Config, config})

      pid = Process.whereis(Config)
      send(pid, {:random_message, :data})
      send(pid, :unknown)
      Process.sleep(10)

      # Should still be alive and functional
      assert Process.alive?(pid)
      assert Config.get(:port) == config.port
    end

    test "file_event for non-config path is ignored" do
      config = Config.load()
      start_supervised!({Config, config})

      pid = Process.whereis(Config)
      # Send a file_event for a different path
      send(pid, {:file_event, nil, {"/tmp/not_config.toml", [:modified]}})
      Process.sleep(10)

      assert Process.alive?(pid)
      # Config should be unchanged
      assert Config.get() == config
    end
  end

  describe "config validation" do
    test "port is clamped to valid range" do
      toml = %{
        "resolved" => %{
          "port" => 0,
          "upstreams" => []
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.port >= 1
      assert config.port <= 65_535
    end

    test "port above 65535 is clamped down" do
      toml = %{
        "resolved" => %{
          "port" => 99_999,
          "upstreams" => []
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.port == 65_535
    end

    test "upstream_timeout_ms is clamped to valid range" do
      toml = %{
        "resolved" => %{
          "upstream_timeout_ms" => 0,
          "upstreams" => []
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.upstream_timeout_ms >= 100
    end

    test "cache min_ttl_s cannot exceed max_ttl_s" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "cache" => %{
            "min_ttl_s" => 9999,
            "max_ttl_s" => 100
          }
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.cache.min_ttl_s <= config.cache.max_ttl_s
    end

    test "cache min_ttl_s > max_ttl_s emits a warning log" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "cache" => %{
            "min_ttl_s" => 500,
            "max_ttl_s" => 100
          }
        }
      }

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          Config.parse_toml_for_test(toml)
        end)

      assert log =~ "min_ttl_s"
      assert log =~ "max_ttl_s"
    end

    test "cache max_entries is at least 1" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "cache" => %{"max_entries" => -5}
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.cache.max_entries >= 1
    end

    test "non-integer values fall back to minimum" do
      toml = %{
        "resolved" => %{
          "port" => "not_a_number",
          "upstreams" => []
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert is_integer(config.port)
    end

    test "intercept rule TTL is clamped" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "test.local", "type" => "A", "value" => "1.2.3.4", "ttl" => 9_999_999}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      [rule] = config.intercept_rules
      assert rule.ttl <= 604_800
    end

    test "intercept rule with invalid IPv4 value is skipped with warning" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "bad.local", "type" => "A", "value" => "not-an-ip"},
            %{"match" => "good.local", "type" => "A", "value" => "10.0.0.1"}
          ]
        }
      }

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          config = Config.parse_toml_for_test(toml)
          # Only the valid rule should be kept
          assert length(config.intercept_rules) == 1
          [rule] = config.intercept_rules
          assert {:exact, "good.local"} = rule.match
        end)

      assert log =~ "Skipping invalid intercept rule"
      assert log =~ "not-an-ip"
    end

    test "intercept rule with invalid IPv6 value is skipped" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "bad.local", "type" => "AAAA", "value" => "not::valid::ipv6::addr"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.intercept_rules == []
    end

    test "intercept rule with invalid MX format is skipped" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "bad.local", "type" => "MX", "value" => "mail.example.com"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.intercept_rules == []
    end

    test "intercept rule with invalid SRV format is skipped" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "bad.local", "type" => "SRV", "value" => "10 sip.example.com"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert config.intercept_rules == []
    end

    test "valid CNAME and TXT rules are kept regardless of value format" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "alias.local", "type" => "CNAME", "value" => "real.example.com"},
            %{"match" => "txt.local", "type" => "TXT", "value" => "v=spf1 include:example.com ~all"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert length(config.intercept_rules) == 2
    end

    test "valid MX rule with correct format is kept" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "mail.local", "type" => "MX", "value" => "10 mail.example.com"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert length(config.intercept_rules) == 1
    end

    test "valid SRV rule with correct format is kept" do
      toml = %{
        "resolved" => %{
          "upstreams" => [],
          "intercept" => [
            %{"match" => "_sip._tcp.local", "type" => "SRV", "value" => "10 20 5060 sip.example.com"}
          ]
        }
      }

      config = Config.parse_toml_for_test(toml)
      assert length(config.intercept_rules) == 1
    end
  end

  describe "TOML config file parsing" do
    test "writes and reads a temporary TOML config" do
      toml_content = """
      [resolved]
      listen = "127.0.0.1"
      port = 5353
      upstreams = ["9.9.9.9"]
      upstream_timeout_ms = 2000
      upstream_failure_threshold = 5

      [resolved.cache]
      enabled = false
      max_entries = 500

      [resolved.discovery]
      enabled = false

      [[resolved.intercept]]
      match = "test.local"
      type = "A"
      value = "10.0.0.1"
      ttl = 120
      """

      tmp_path =
        Path.join(System.tmp_dir!(), "test_resolved_#{System.unique_integer([:positive])}.toml")

      File.write!(tmp_path, toml_content)

      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, parsed} = Toml.decode_file(tmp_path)
      resolved = parsed["resolved"]

      assert resolved["port"] == 5353
      assert resolved["upstreams"] == ["9.9.9.9"]
      assert resolved["upstream_timeout_ms"] == 2000
      assert resolved["cache"]["enabled"] == false
      assert resolved["cache"]["max_entries"] == 500
      assert resolved["discovery"]["enabled"] == false
      assert length(resolved["intercept"]) == 1

      [rule] = resolved["intercept"]
      assert rule["match"] == "test.local"
      assert rule["type"] == "A"
      assert rule["value"] == "10.0.0.1"
      assert rule["ttl"] == 120
    end
  end
end
