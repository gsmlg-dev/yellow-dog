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
  end
end
