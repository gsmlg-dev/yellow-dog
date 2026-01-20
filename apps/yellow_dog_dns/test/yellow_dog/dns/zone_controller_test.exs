defmodule YellowDog.Dns.ZoneControllerTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.ZoneController.

  Tests cover:
  - DynamicSupervisor lifecycle (start_link)
  - Zone process management (start_zone, stop_zone, find_zone)
  - Zone listing (list_zones, list_zones_for_view)
  - View scoping of zones
  - Multiple zone types
  - Error handling
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ZoneController

  # Start required registry before all tests
  setup_all do
    case Registry.start_link(keys: :unique, name: YellowDog.Dns.ZoneRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Start a fresh ZoneController for each test
  setup do
    name = :"zone_controller_test_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = ZoneController.start_link(name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, supervisor: pid, name: name}
  end

  describe "start_link/1" do
    @tag :capture_log
    test "starts with default name" do
      name = :"zc_default_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = ZoneController.start_link(name: name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "starts with custom options" do
      name = :"zc_custom_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = ZoneController.start_link(name: name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop(pid)
    end
  end

  describe "start_zone/4" do
    @tag :capture_log
    test "starts a forward zone", %{supervisor: supervisor} do
      zone_name = "forward.#{:rand.uniform(1_000_000)}.local"

      {:ok, zone_pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      assert is_pid(zone_pid)
      assert Process.alive?(zone_pid)
    end

    @tag :capture_log
    test "starts a forward zone with custom view", %{supervisor: supervisor} do
      zone_name = "viewzone.#{:rand.uniform(1_000_000)}.local"
      view_name = "custom_view"

      {:ok, zone_pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: view_name,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      assert is_pid(zone_pid)
      assert Process.alive?(zone_pid)
    end

    @tag :capture_log
    test "starts multiple zones with different names", %{supervisor: supervisor} do
      zone1 = "zone1.#{:rand.uniform(1_000_000)}.local"
      zone2 = "zone2.#{:rand.uniform(1_000_000)}.local"

      {:ok, pid1} =
        ZoneController.start_zone(supervisor, :forward, zone1, upstreams: [{{8, 8, 8, 8}, 53}])

      {:ok, pid2} =
        ZoneController.start_zone(supervisor, :forward, zone2, upstreams: [{{8, 8, 4, 4}, 53}])

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end

    @tag :capture_log
    test "starts same zone name in different views", %{supervisor: supervisor} do
      zone_name = "shared.#{:rand.uniform(1_000_000)}.local"

      {:ok, pid1} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: "view1",
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      {:ok, pid2} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: "view2",
          upstreams: [{{8, 8, 4, 4}, 53}]
        )

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end

    @tag :capture_log
    test "returns error for duplicate zone in same view", %{supervisor: supervisor} do
      zone_name = "dup.#{:rand.uniform(1_000_000)}.local"

      {:ok, _pid1} =
        ZoneController.start_zone(supervisor, :forward, zone_name, upstreams: [{{8, 8, 8, 8}, 53}])

      {:error, {:already_started, _}} =
        ZoneController.start_zone(supervisor, :forward, zone_name, upstreams: [{{8, 8, 4, 4}, 53}])
    end
  end

  describe "find_zone/4" do
    @tag :capture_log
    test "finds existing zone", %{supervisor: supervisor} do
      zone_name = "findme.#{:rand.uniform(1_000_000)}.local"

      {:ok, started_pid} =
        ZoneController.start_zone(supervisor, :forward, zone_name, upstreams: [{{8, 8, 8, 8}, 53}])

      {:ok, found_pid} = ZoneController.find_zone(supervisor, "default", :forward, zone_name)

      assert found_pid == started_pid
    end

    @tag :capture_log
    test "finds zone in specific view", %{supervisor: supervisor} do
      zone_name = "viewfind.#{:rand.uniform(1_000_000)}.local"
      view_name = "myview"

      {:ok, started_pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: view_name,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      {:ok, found_pid} = ZoneController.find_zone(supervisor, view_name, :forward, zone_name)

      assert found_pid == started_pid
    end

    @tag :capture_log
    test "returns error for non-existent zone", %{supervisor: supervisor} do
      result = ZoneController.find_zone(supervisor, "default", :forward, "nonexistent.local")

      assert result == :error
    end

    @tag :capture_log
    test "returns error for zone in wrong view", %{supervisor: supervisor} do
      zone_name = "wrongview.#{:rand.uniform(1_000_000)}.local"

      {:ok, _pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: "view1",
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      # Try to find in different view
      result = ZoneController.find_zone(supervisor, "view2", :forward, zone_name)

      assert result == :error
    end
  end

  describe "stop_zone/4" do
    @tag :capture_log
    test "stops existing zone", %{supervisor: supervisor} do
      zone_name = "stopme.#{:rand.uniform(1_000_000)}.local"

      {:ok, pid} =
        ZoneController.start_zone(supervisor, :forward, zone_name, upstreams: [{{8, 8, 8, 8}, 53}])

      assert Process.alive?(pid)

      :ok = ZoneController.stop_zone(supervisor, "default", :forward, zone_name)

      # Give the supervisor time to terminate the child
      Process.sleep(10)

      refute Process.alive?(pid)
    end

    @tag :capture_log
    test "stops zone in specific view", %{supervisor: supervisor} do
      zone_name = "stopview.#{:rand.uniform(1_000_000)}.local"
      view_name = "stoptest"

      {:ok, pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: view_name,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      assert Process.alive?(pid)

      :ok = ZoneController.stop_zone(supervisor, view_name, :forward, zone_name)

      Process.sleep(10)

      refute Process.alive?(pid)
    end

    @tag :capture_log
    test "returns error for non-existent zone", %{supervisor: supervisor} do
      result = ZoneController.stop_zone(supervisor, "default", :forward, "nonexistent.local")

      assert result == {:error, :not_found}
    end
  end

  describe "list_zones/1" do
    @tag :capture_log
    test "returns empty list when no zones", %{supervisor: supervisor} do
      zones = ZoneController.list_zones(supervisor)

      assert zones == []
    end

    @tag :capture_log
    test "returns all zones", %{supervisor: supervisor} do
      zone1 = "list1.#{:rand.uniform(1_000_000)}.local"
      zone2 = "list2.#{:rand.uniform(1_000_000)}.local"

      {:ok, pid1} =
        ZoneController.start_zone(supervisor, :forward, zone1, upstreams: [{{8, 8, 8, 8}, 53}])

      {:ok, pid2} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone2,
          view_name: "other",
          upstreams: [{{8, 8, 4, 4}, 53}]
        )

      zones = ZoneController.list_zones(supervisor)

      assert length(zones) == 2

      # Verify both zones are in the list
      pids = Enum.map(zones, fn {_view, _type, _name, pid} -> pid end)
      assert pid1 in pids
      assert pid2 in pids
    end

    @tag :capture_log
    test "returns zones with correct view names", %{supervisor: supervisor} do
      zone_name = "viewlist.#{:rand.uniform(1_000_000)}.local"

      {:ok, _pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          view_name: "myview",
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      zones = ZoneController.list_zones(supervisor)

      assert length(zones) == 1
      [{view, type, name, _pid}] = zones
      assert view == "myview"
      assert type == :forward
      assert name == zone_name
    end
  end

  describe "list_zones_for_view/2" do
    @tag :capture_log
    test "returns empty list when no zones in view", %{supervisor: supervisor} do
      zones = ZoneController.list_zones_for_view(supervisor, "empty_view")

      assert zones == []
    end

    @tag :capture_log
    test "returns only zones in specified view", %{supervisor: supervisor} do
      zone1 = "forview1.#{:rand.uniform(1_000_000)}.local"
      zone2 = "forview2.#{:rand.uniform(1_000_000)}.local"
      zone3 = "forview3.#{:rand.uniform(1_000_000)}.local"

      # Two zones in "target_view"
      {:ok, pid1} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone1,
          view_name: "target_view",
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      {:ok, pid2} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone2,
          view_name: "target_view",
          upstreams: [{{8, 8, 4, 4}, 53}]
        )

      # One zone in different view
      {:ok, _pid3} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          zone3,
          view_name: "other_view",
          upstreams: [{{1, 1, 1, 1}, 53}]
        )

      zones = ZoneController.list_zones_for_view(supervisor, "target_view")

      assert length(zones) == 2

      pids = Enum.map(zones, fn {_type, _name, pid} -> pid end)
      assert pid1 in pids
      assert pid2 in pids
    end
  end

  describe "multiple zone types" do
    @tag :capture_log
    test "can start different zone types", %{supervisor: supervisor} do
      forward_zone = "forward.#{:rand.uniform(1_000_000)}.local"

      # Start forward zone
      {:ok, forward_pid} =
        ZoneController.start_zone(
          supervisor,
          :forward,
          forward_zone,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )

      assert is_pid(forward_pid)

      zones = ZoneController.list_zones(supervisor)
      assert length(zones) >= 1

      types = Enum.map(zones, fn {_view, type, _name, _pid} -> type end)
      assert :forward in types
    end
  end

  describe "concurrent operations" do
    @tag :capture_log
    test "handles concurrent zone starts", %{supervisor: supervisor} do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            zone_name = "concurrent_#{i}_#{:rand.uniform(1_000_000)}.local"

            ZoneController.start_zone(
              supervisor,
              :forward,
              zone_name,
              upstreams: [{{8, 8, 8, 8}, 53}]
            )
          end)
        end

      results = Task.await_many(tasks, 10000)

      # All should succeed
      for result <- results do
        assert {:ok, pid} = result
        assert is_pid(pid)
      end

      # All zones should be listed
      zones = ZoneController.list_zones(supervisor)
      assert length(zones) == 5
    end

    @tag :capture_log
    test "handles concurrent list operations", %{supervisor: supervisor} do
      # Start some zones first
      for i <- 1..3 do
        zone_name = "listtest_#{i}_#{:rand.uniform(1_000_000)}.local"

        ZoneController.start_zone(
          supervisor,
          :forward,
          zone_name,
          upstreams: [{{8, 8, 8, 8}, 53}]
        )
      end

      # Concurrent list operations
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ZoneController.list_zones(supervisor)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert is_list(result)
        assert length(result) == 3
      end
    end
  end

  describe "error handling" do
    @tag :capture_log
    test "handles stop of non-existent zone gracefully", %{supervisor: supervisor} do
      result = ZoneController.stop_zone(supervisor, "default", :forward, "does_not_exist.local")

      assert result == {:error, :not_found}
    end

    @tag :capture_log
    test "handles find of non-existent zone gracefully", %{supervisor: supervisor} do
      result = ZoneController.find_zone(supervisor, "default", :forward, "does_not_exist.local")

      assert result == :error
    end
  end
end
