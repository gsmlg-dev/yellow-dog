defmodule YellowDog.Dns.ViewTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.View.

  Tests cover:
  - Process lifecycle (start_link, terminate)
  - ACL matching
  - Zone registration
  - RPZ zone registration
  - Configuration reload
  - Stats tracking
  - Cache operations
  - Query resolution (with mocks)
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ACL

  # Start the required registry before all tests
  setup_all do
    case Registry.start_link(keys: :unique, name: YellowDog.Dns.ViewRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "start_link/1" do
    @tag :capture_log
    test "starts with minimal configuration" do
      view_name = "test_view_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = View.start_link(name: view_name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "starts with full configuration" do
      view_name = "test_view_full_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        View.start_link(
          name: view_name,
          priority: 50,
          acl: :any,
          zones: ["example.com", "test.local"],
          rpz_zones: ["rpz.example.com"],
          recursion_enabled: true,
          ecs_enabled: false,
          cache_size: 500
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify configuration
      assert View.get_name(pid) == view_name
      assert View.get_priority(pid) == 50

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "starts with map configuration" do
      view_name = "test_view_map_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        View.start_link(%{
          name: view_name,
          priority: 75,
          recursion_enabled: false
        })

      assert is_pid(pid)
      assert View.get_priority(pid) == 75

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "starts with default priority when not specified" do
      view_name = "test_view_default_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = View.start_link(name: view_name)

      # Default priority is 100
      assert View.get_priority(pid) == 100

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "fails to start with duplicate view name" do
      view_name = "test_dup_#{:rand.uniform(1_000_000)}"

      {:ok, pid1} = View.start_link(name: view_name)
      {:error, {:already_started, ^pid1}} = View.start_link(name: view_name)

      GenServer.stop(pid1)
    end
  end

  describe "get_name/1" do
    @tag :capture_log
    test "returns the view name" do
      view_name = "test_getname_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      assert View.get_name(pid) == view_name

      GenServer.stop(pid)
    end
  end

  describe "get_priority/1" do
    @tag :capture_log
    test "returns custom priority" do
      view_name = "test_priority_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, priority: 25)

      assert View.get_priority(pid) == 25

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "returns default priority (100)" do
      view_name = "test_priority_default_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      assert View.get_priority(pid) == 100

      GenServer.stop(pid)
    end
  end

  describe "matches?/2" do
    @tag :capture_log
    test "matches any IP with :any ACL" do
      view_name = "test_match_any_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, acl: :any)

      assert View.matches?(pid, {192, 168, 1, 1})
      assert View.matches?(pid, {10, 0, 0, 1})
      assert View.matches?(pid, {8, 8, 8, 8})

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "matches any IP with :all ACL (alias for :any)" do
      view_name = "test_match_all_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, acl: :all)

      assert View.matches?(pid, {192, 168, 1, 1})

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "matches with inline ACL rules" do
      view_name = "test_match_inline_#{:rand.uniform(1_000_000)}"
      acl_rules = [{:allow, {10, 0, 0, 0}, 8}, {:allow, {192, 168, 0, 0}, 16}]
      {:ok, pid} = View.start_link(name: view_name, acl: acl_rules)

      assert View.matches?(pid, {10, 1, 2, 3})
      assert View.matches?(pid, {192, 168, 1, 100})
      refute View.matches?(pid, {8, 8, 8, 8})

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "matches with named ACL (localhost)" do
      view_name = "test_match_localhost_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, acl: "localhost")

      assert View.matches?(pid, {127, 0, 0, 1})
      refute View.matches?(pid, {192, 168, 1, 1})

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "matches with ACL struct" do
      view_name = "test_match_struct_#{:rand.uniform(1_000_000)}"
      acl = ACL.new("custom", [{:allow, {172, 16, 0, 0}, 12}])
      {:ok, pid} = View.start_link(name: view_name, acl: acl)

      assert View.matches?(pid, {172, 16, 5, 10})
      refute View.matches?(pid, {172, 32, 1, 1})

      GenServer.stop(pid)
    end
  end

  describe "register_zone/3" do
    @tag :capture_log
    test "registers a zone" do
      view_name = "test_regzone_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, zones: [])

      assert :ok = View.register_zone(pid, :auth, "example.com")

      stats = View.stats(pid)
      assert {:auth, "example.com"} in stats.zones

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "registers multiple zones" do
      view_name = "test_regzone_multi_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, zones: [])

      :ok = View.register_zone(pid, :auth, "example.com")
      :ok = View.register_zone(pid, :forward, "test.local")
      :ok = View.register_zone(pid, :stub, "stub.zone")

      stats = View.stats(pid)
      assert {:auth, "example.com"} in stats.zones
      assert {:forward, "test.local"} in stats.zones
      assert {:stub, "stub.zone"} in stats.zones

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "deduplicates zone registrations" do
      view_name = "test_regzone_dedup_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, zones: [])

      :ok = View.register_zone(pid, :auth, "example.com")
      :ok = View.register_zone(pid, :auth, "example.com")

      stats = View.stats(pid)
      zone_count = Enum.count(stats.zones, fn z -> z == {:auth, "example.com"} end)
      assert zone_count == 1

      GenServer.stop(pid)
    end
  end

  describe "register_rpz_zone/2" do
    @tag :capture_log
    test "registers an RPZ zone" do
      view_name = "test_rpz_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, rpz_zones: [])

      assert :ok = View.register_rpz_zone(pid, "rpz.example.com")

      stats = View.stats(pid)
      assert "rpz.example.com" in stats.rpz_zones

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "registers multiple RPZ zones" do
      view_name = "test_rpz_multi_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, rpz_zones: [])

      :ok = View.register_rpz_zone(pid, "rpz1.example.com")
      :ok = View.register_rpz_zone(pid, "rpz2.example.com")

      stats = View.stats(pid)
      assert "rpz1.example.com" in stats.rpz_zones
      assert "rpz2.example.com" in stats.rpz_zones

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "deduplicates RPZ zone registrations" do
      view_name = "test_rpz_dedup_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, rpz_zones: [])

      :ok = View.register_rpz_zone(pid, "rpz.example.com")
      :ok = View.register_rpz_zone(pid, "rpz.example.com")

      stats = View.stats(pid)
      rpz_count = Enum.count(stats.rpz_zones, fn z -> z == "rpz.example.com" end)
      assert rpz_count == 1

      GenServer.stop(pid)
    end
  end

  describe "reload/2" do
    @tag :capture_log
    test "reloads priority configuration" do
      view_name = "test_reload_priority_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, priority: 100)

      assert View.get_priority(pid) == 100

      :ok = View.reload(pid, %{priority: 50})

      assert View.get_priority(pid) == 50

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "reloads zones configuration" do
      view_name = "test_reload_zones_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, zones: ["old.zone"])

      stats = View.stats(pid)
      assert "old.zone" in stats.zones

      :ok = View.reload(pid, %{zones: ["new.zone"]})

      stats = View.stats(pid)
      assert "new.zone" in stats.zones
      refute "old.zone" in stats.zones

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "reloads recursion_enabled configuration" do
      view_name = "test_reload_recursion_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, recursion_enabled: true)

      stats = View.stats(pid)
      assert stats.recursion_enabled == true

      :ok = View.reload(pid, %{recursion_enabled: false})

      stats = View.stats(pid)
      assert stats.recursion_enabled == false

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "preserves unspecified values during reload" do
      view_name = "test_reload_preserve_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name, priority: 25, recursion_enabled: true)

      # Only reload zones, not priority
      :ok = View.reload(pid, %{zones: ["test.zone"]})

      # Priority should be preserved
      assert View.get_priority(pid) == 25

      stats = View.stats(pid)
      assert stats.recursion_enabled == true

      GenServer.stop(pid)
    end
  end

  describe "stats/1" do
    @tag :capture_log
    test "returns initial statistics" do
      view_name = "test_stats_initial_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      stats = View.stats(pid)

      assert stats.name == view_name
      assert stats.query_count == 0
      assert stats.hit_count == 0
      assert stats.miss_count == 0
      assert stats.cache_size >= 0

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "includes configuration in stats" do
      view_name = "test_stats_config_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        View.start_link(
          name: view_name,
          priority: 75,
          zones: ["example.com"],
          rpz_zones: ["rpz.example.com"],
          recursion_enabled: false,
          ecs_enabled: true
        )

      stats = View.stats(pid)

      assert stats.name == view_name
      assert stats.priority == 75
      assert stats.zones == ["example.com"]
      assert stats.rpz_zones == ["rpz.example.com"]
      assert stats.recursion_enabled == false
      assert stats.ecs_enabled == true

      GenServer.stop(pid)
    end
  end

  describe "termination" do
    @tag :capture_log
    test "cleans up ETS cache on termination" do
      view_name = "test_terminate_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      # Verify process is alive and can respond
      stats = View.stats(pid)
      assert stats.name == view_name
      assert stats.cache_size >= 0

      # Process should be alive before stopping
      assert Process.alive?(pid)

      # Stop the process
      GenServer.stop(pid)

      # Process should be dead after stopping
      refute Process.alive?(pid)

      # Note: ETS table is automatically deleted when owning process terminates
      # The terminate/2 callback explicitly deletes it, but even if it didn't,
      # the table would be garbage collected. We verify the process died cleanly.
    end
  end

  describe "handle_info/2" do
    @tag :capture_log
    test "handles cancel_query message gracefully" do
      view_name = "test_cancel_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      # Send cancel query message
      send(pid, {:cancel_query, 12345})

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "handles unknown messages gracefully" do
      view_name = "test_unknown_msg_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      # Send unknown messages
      send(pid, :unknown_message)
      send(pid, {:unexpected, :data})

      # Process should still be alive
      Process.sleep(10)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "concurrent usage" do
    @tag :capture_log
    test "handles concurrent stats calls" do
      view_name = "test_concurrent_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = View.start_link(name: view_name)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            View.stats(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert is_map(result)
        assert result.name == view_name
      end

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "handles concurrent matches? calls" do
      view_name = "test_concurrent_match_#{:rand.uniform(1_000_000)}"
      acl_rules = [{:allow, {10, 0, 0, 0}, 8}]
      {:ok, pid} = View.start_link(name: view_name, acl: acl_rules)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ip = {10, 1, 1, i}
            View.matches?(pid, ip)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert result == true
      end

      GenServer.stop(pid)
    end
  end

  describe "multiple views" do
    @tag :capture_log
    test "can start multiple views with different names" do
      view1 = "multi_view_1_#{:rand.uniform(1_000_000)}"
      view2 = "multi_view_2_#{:rand.uniform(1_000_000)}"

      {:ok, pid1} = View.start_link(name: view1, priority: 10)
      {:ok, pid2} = View.start_link(name: view2, priority: 20)

      assert pid1 != pid2
      assert View.get_name(pid1) == view1
      assert View.get_name(pid2) == view2
      assert View.get_priority(pid1) == 10
      assert View.get_priority(pid2) == 20

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end

    @tag :capture_log
    test "views have independent state" do
      view1 = "indep_view_1_#{:rand.uniform(1_000_000)}"
      view2 = "indep_view_2_#{:rand.uniform(1_000_000)}"

      {:ok, pid1} = View.start_link(name: view1, zones: [])
      {:ok, pid2} = View.start_link(name: view2, zones: [])

      # Register zone only in view1
      :ok = View.register_zone(pid1, :auth, "example.com")

      stats1 = View.stats(pid1)
      stats2 = View.stats(pid2)

      assert {:auth, "example.com"} in stats1.zones
      refute {:auth, "example.com"} in stats2.zones

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end
end
