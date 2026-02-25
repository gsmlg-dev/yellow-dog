defmodule YellowDog.Resolved.ManagementTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.{Cache, Config, Metrics}
  alias YellowDog.Resolved.Management.Handler

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  @config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 200,
    upstream_failure_threshold: 3,
    intercept_rules: [
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
    ],
    cache: @cache_config,
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    config_path: ""
  }

  setup do
    start_supervised!({Config, @config})
    start_supervised!({Cache, @cache_config})
    start_supervised!(Metrics)
    :ok
  end

  describe "handle_command cache_flush" do
    test "flushes all entries" do
      Cache.store("test.com", :a, "data", 300)
      Process.sleep(10)

      response =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-001",
          "data" => %{"pattern" => nil}
        })

      assert response["type"] == "cache_flush_result"
      assert response["id"] == "req-001"
      assert response["data"]["flushed"] >= 1

      assert :miss = Cache.lookup("test.com", :a)
    end

    test "flushes by pattern" do
      Cache.store("sub1.example.com", :a, "data1", 300)
      Cache.store("sub2.example.com", :a, "data2", 300)
      Cache.store("other.test", :a, "data3", 300)
      Process.sleep(10)

      response =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-002",
          "data" => %{"pattern" => "*.example.com"}
        })

      assert response["data"]["flushed"] == 2
      assert :miss = Cache.lookup("sub1.example.com", :a)
      assert {:hit, "data3"} = Cache.lookup("other.test", :a)
    end
  end

  describe "handle_command cache_stats" do
    test "returns cache statistics" do
      Cache.store("test.com", :a, "data", 300)
      Process.sleep(10)
      Cache.lookup("test.com", :a)
      Cache.lookup("miss.com", :a)

      response =
        Handler.handle_command(%{
          "type" => "cache_stats",
          "id" => "req-003"
        })

      assert response["type"] == "cache_stats_result"
      assert response["id"] == "req-003"
      assert response["data"]["entries"] == 1
      assert response["data"]["hits"] >= 1
      assert response["data"]["misses"] >= 1
    end
  end

  describe "handle_command ping" do
    test "returns pong with uptime" do
      response =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-004",
          "data" => %{"server_time" => 1_706_000_000}
        })

      assert response["type"] == "pong"
      assert response["id"] == "req-004"
      assert is_integer(response["data"]["uptime_s"])
    end
  end

  describe "handle_command unknown" do
    test "returns nil for unknown command" do
      log =
        capture_log(fn ->
          assert nil == Handler.handle_command(%{"type" => "unknown"})
        end)

      assert log =~ "Unknown management command"
    end
  end

  describe "handle_command cache_flush on empty cache" do
    test "flushes zero entries from empty cache" do
      response =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-010",
          "data" => %{"pattern" => nil}
        })

      assert response["type"] == "cache_flush_result"
      assert response["data"]["flushed"] == 0
    end
  end

  describe "handle_command cache_stats on empty cache" do
    test "returns zero stats" do
      response =
        Handler.handle_command(%{
          "type" => "cache_stats",
          "id" => "req-011"
        })

      assert response["data"]["entries"] == 0
      assert response["data"]["hit_rate"] == 0.0
      assert response["data"]["oldest_entry_age_s"] == 0
    end
  end

  describe "handle_command ping response fields" do
    test "includes all expected counter fields" do
      response =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-012",
          "data" => %{}
        })

      data = response["data"]
      assert Map.has_key?(data, "uptime_s")
      assert Map.has_key?(data, "queries_total")
      assert Map.has_key?(data, "queries_intercepted")
      assert Map.has_key?(data, "queries_cached")
      assert Map.has_key?(data, "queries_forwarded")
    end
  end

  describe "build_connected_event/1 with live Config" do
    test "includes real upstream addresses" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      upstreams = event["data"]["upstreams"]
      assert is_list(upstreams)
      assert length(upstreams) == 1
      # @config has [{198, 51, 100, 1}] — Upstream.format/1 turns it into a string
      assert hd(upstreams) =~ "198.51.100.1"
    end

    test "includes real intercept rule count" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      assert event["data"]["intercept_rule_count"] == 1
    end

    test "includes real cache max_entries" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      assert event["data"]["cache_max_entries"] == 1000
    end
  end

  describe "build_connected_event/1 fallback when Config unavailable" do
    test "returns default values when Config GenServer not running" do
      # Stop Config so fetch_config_summary hits the rescue path
      stop_supervised!(Config)
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      assert event["type"] == "connected"
      assert event["data"]["upstreams"] == []
      assert event["data"]["intercept_rule_count"] == 0
      assert event["data"]["cache_max_entries"] == 10_000
    end
  end

  describe "build_connected_event/1" do
    test "builds connected event" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      assert event["type"] == "connected"
      assert String.starts_with?(event["id"], "evt-")
      assert event["data"]["version"] == "0.1.0"
      assert is_binary(event["data"]["hostname"])
      assert is_binary(event["data"]["instance_id"])
    end

    test "instance_id is hex-encoded" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      hex_id = event["data"]["instance_id"]
      assert String.length(hex_id) == 32
      assert hex_id == Base.encode16(instance_id, case: :lower)
    end

    test "unique event IDs across calls" do
      id1 = :crypto.strong_rand_bytes(16)
      id2 = :crypto.strong_rand_bytes(16)

      event1 = Handler.build_connected_event(id1)
      event2 = Handler.build_connected_event(id2)

      assert event1["id"] != event2["id"]
    end
  end
end
