defmodule YellowDog.Resolved.ManagementTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config}
  alias YellowDog.Resolved.Management.Handler

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [{8, 8, 8, 8}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 1000,
      min_ttl_s: 5,
      max_ttl_s: 3600,
      negative_ttl_s: 30,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: []
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!({Cache, @test_config.cache})
    :ok
  end

  describe "handle_command/1" do
    test "cache_flush with null pattern flushes all" do
      Cache.store("test.com", :a, %{data: "test"}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-001",
          "data" => %{"pattern" => nil}
        })

      assert result["type"] == "cache_flush_result"
      assert result["id"] == "req-001"
      assert result["data"]["flushed"] >= 1
    end

    test "cache_flush with domain pattern" do
      Cache.store("sub.example.com", :a, %{}, 300)
      Cache.store("other.com", :a, %{}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-002",
          "data" => %{"pattern" => "*.example.com"}
        })

      assert result["type"] == "cache_flush_result"
      assert result["data"]["flushed"] >= 1
    end

    test "cache_stats returns statistics" do
      Cache.store("test.com", :a, %{}, 300)
      Process.sleep(10)
      Cache.lookup("test.com", :a)
      Cache.lookup("miss.com", :a)

      result =
        Handler.handle_command(%{
          "type" => "cache_stats",
          "id" => "req-003",
          "data" => %{}
        })

      assert result["type"] == "cache_stats_result"
      assert result["id"] == "req-003"
      assert is_integer(result["data"]["entries"])
      assert is_integer(result["data"]["hits"])
      assert is_integer(result["data"]["misses"])
    end

    test "ping returns pong with stats" do
      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-004",
          "data" => %{"server_time" => 1_706_000_000}
        })

      assert result["type"] == "pong"
      assert result["id"] == "req-004"
      assert is_integer(result["data"]["uptime_s"])
      assert is_integer(result["data"]["queries_total"])
    end

    test "unknown command returns nil" do
      assert nil == Handler.handle_command(%{"type" => "unknown"})
    end
  end

  describe "connected_event/1" do
    test "builds correct connected event structure" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.connected_event(instance_id)

      assert event["type"] == "connected"
      assert is_binary(event["data"]["instance_id"])
      assert event["data"]["version"] == "0.1.0"
      assert is_binary(event["data"]["hostname"])
      assert is_list(event["data"]["upstreams"])
    end
  end
end
