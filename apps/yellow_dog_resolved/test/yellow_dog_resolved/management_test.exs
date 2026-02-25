defmodule YellowDog.Resolved.ManagementTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Cache
  alias YellowDog.Resolved.Management.Handler

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  setup do
    start_supervised!({Cache, @cache_config})
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
      assert nil == Handler.handle_command(%{"type" => "unknown"})
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
  end
end
