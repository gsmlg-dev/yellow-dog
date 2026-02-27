defmodule YellowDog.Resolved.Management.HandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.{Cache, Metrics}
  alias YellowDog.Resolved.Management.Handler

  @cache_config %{
    enabled: true,
    max_entries: 100,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 10,
    sweep_interval_s: 3600
  }

  setup do
    start_supervised!({Cache, @cache_config})
    start_supervised!(Metrics)
    :ok
  end

  # ── handle_command: cache_flush ──────────────────────────────────

  describe "handle_command cache_flush" do
    test "flushes all cache entries and returns count" do
      Cache.store("one.test", :a, "resp1", 300)
      Cache.store("two.test", :a, "resp2", 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "cmd-1",
          "data" => %{}
        })

      assert result["type"] == "cache_flush_result"
      assert result["id"] == "cmd-1"
      assert is_integer(result["data"]["flushed"])
      assert result["data"]["flushed"] >= 2
    end

    test "flushes by pattern and returns count" do
      Cache.store("a.example.com", :a, "resp1", 300)
      Cache.store("b.example.com", :a, "resp2", 300)
      Cache.store("other.test", :a, "resp3", 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "cmd-2",
          "data" => %{"pattern" => "*.example.com"}
        })

      assert result["type"] == "cache_flush_result"
      assert result["id"] == "cmd-2"
      assert is_integer(result["data"]["flushed"])
    end

    test "emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-mgmt-flush",
        [:yellow_dog, :resolved, :management, :command],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      Handler.handle_command(%{
        "type" => "cache_flush",
        "id" => "cmd-tel",
        "data" => %{}
      })

      assert_receive {:telemetry, %{type: :cache_flush}}
      :telemetry.detach("test-mgmt-flush")
    end
  end

  # ── handle_command: cache_stats ──────────────────────────────────

  describe "handle_command cache_stats" do
    test "returns cache statistics" do
      Cache.store("stats.test", :a, "response", 300)
      Process.sleep(10)

      # Generate a hit
      Cache.lookup("stats.test", :a)
      # Generate a miss
      Cache.lookup("missing.test", :a)

      result =
        Handler.handle_command(%{
          "type" => "cache_stats",
          "id" => "cmd-3"
        })

      assert result["type"] == "cache_stats_result"
      assert result["id"] == "cmd-3"

      data = result["data"]
      assert is_integer(data["entries"])
      assert is_integer(data["hits"])
      assert is_integer(data["misses"])
      assert is_integer(data["evictions"])
      assert is_float(data["hit_rate"]) or is_integer(data["hit_rate"])
      assert is_integer(data["oldest_entry_age_s"]) or is_float(data["oldest_entry_age_s"])
    end

    test "emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-mgmt-stats",
        [:yellow_dog, :resolved, :management, :command],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      Handler.handle_command(%{
        "type" => "cache_stats",
        "id" => "cmd-tel-stats"
      })

      assert_receive {:telemetry, %{type: :cache_stats}}
      :telemetry.detach("test-mgmt-stats")
    end
  end

  # ── handle_command: ping ─────────────────────────────────────────

  describe "handle_command ping" do
    test "returns pong with uptime and query counts" do
      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "cmd-4",
          "data" => %{}
        })

      assert result["type"] == "pong"
      assert result["id"] == "cmd-4"

      data = result["data"]
      assert is_integer(data["uptime_s"])
      assert is_integer(data["queries_total"])
      assert is_integer(data["queries_intercepted"])
      assert is_integer(data["queries_cached"])
      assert is_integer(data["queries_forwarded"])
    end

    test "emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-mgmt-ping",
        [:yellow_dog, :resolved, :management, :command],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      Handler.handle_command(%{
        "type" => "ping",
        "id" => "cmd-tel-ping",
        "data" => %{}
      })

      assert_receive {:telemetry, %{type: :ping}}
      :telemetry.detach("test-mgmt-ping")
    end
  end

  # ── handle_command: unknown ──────────────────────────────────────

  describe "handle_command unknown" do
    test "returns nil for unknown command" do
      log =
        capture_log(fn ->
          result =
            Handler.handle_command(%{
              "type" => "unknown_command",
              "id" => "cmd-5"
            })

          assert result == nil
        end)

      assert log =~ "Unknown management command"
    end

    test "returns nil for empty map" do
      capture_log(fn ->
        assert Handler.handle_command(%{}) == nil
      end)
    end

    test "returns nil for non-map" do
      capture_log(fn ->
        assert Handler.handle_command("not a map") == nil
      end)
    end
  end

  # ── build_connected_event/1 ──────────────────────────────────────

  describe "build_connected_event/1" do
    test "returns event with instance_id and hostname" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      assert event["type"] == "connected"
      assert is_binary(event["id"])
      assert String.starts_with?(event["id"], "evt-")

      data = event["data"]
      assert data["instance_id"] == Base.encode16(instance_id, case: :lower)
      assert data["version"] == "0.1.0"
      assert is_binary(data["hostname"])
      assert is_list(data["upstreams"])
      assert is_integer(data["intercept_rule_count"])
      assert is_integer(data["cache_max_entries"])
    end

    test "generates unique event IDs" do
      id = :crypto.strong_rand_bytes(16)
      event1 = Handler.build_connected_event(id)
      event2 = Handler.build_connected_event(id)
      assert event1["id"] != event2["id"]
    end

    test "handles missing config gracefully" do
      # Config.get() may fail if Config GenServer isn't running;
      # build_connected_event has rescue/catch for this
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.build_connected_event(instance_id)

      # Should still produce a valid event structure
      assert event["type"] == "connected"
      data = event["data"]
      assert is_list(data["upstreams"])
      assert is_integer(data["intercept_rule_count"])
      assert is_integer(data["cache_max_entries"])
    end
  end

  # ── Response structure consistency ───────────────────────────────

  describe "response structure" do
    test "all command responses preserve the request id" do
      for {type, data} <- [
            {"cache_flush", %{"data" => %{}}},
            {"cache_stats", %{}},
            {"ping", %{"data" => %{}}}
          ] do
        cmd = Map.merge(%{"type" => type, "id" => "preserve-id"}, data)
        result = Handler.handle_command(cmd)
        assert result["id"] == "preserve-id", "#{type} did not preserve id"
      end
    end

    test "all command responses have a type field" do
      for {type, data} <- [
            {"cache_flush", %{"data" => %{}}},
            {"cache_stats", %{}},
            {"ping", %{"data" => %{}}}
          ] do
        cmd = Map.merge(%{"type" => type, "id" => "type-check"}, data)
        result = Handler.handle_command(cmd)
        assert is_binary(result["type"]), "#{type} response missing type"
      end
    end

    test "all command responses have a data field" do
      for {type, data} <- [
            {"cache_flush", %{"data" => %{}}},
            {"cache_stats", %{}},
            {"ping", %{"data" => %{}}}
          ] do
        cmd = Map.merge(%{"type" => type, "id" => "data-check"}, data)
        result = Handler.handle_command(cmd)
        assert is_map(result["data"]), "#{type} response missing data map"
      end
    end
  end
end
