defmodule YellowDog.Dns.View.ManagerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.Manager

  describe "start_link/1" do
    test "starts with empty views by default" do
      {:ok, pid} = Manager.start_link(name: nil)
      assert Manager.get_views(pid) == []
      GenServer.stop(pid)
    end

    test "starts with provided initial views" do
      views = [
        View.new("internal", "localnets", [], true),
        View.new("external", "any", [], false)
      ]

      {:ok, pid} = Manager.start_link(views: views, name: nil)
      assert Manager.get_views(pid) == views
      GenServer.stop(pid)
    end

    test "can be started with a custom name" do
      {:ok, _pid} = Manager.start_link(name: :test_manager)
      assert Process.whereis(:test_manager) != nil
      GenServer.stop(:test_manager)
    end
  end

  describe "get_views/1" do
    setup do
      views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false)
      ]

      {:ok, pid} = Manager.start_link(views: views, name: nil)
      %{pid: pid, views: views}
    end

    test "returns current views", %{pid: pid, views: views} do
      assert Manager.get_views(pid) == views
    end

    test "returns empty list when no views configured", %{pid: _pid} do
      {:ok, empty_pid} = Manager.start_link(name: nil)
      assert Manager.get_views(empty_pid) == []
      GenServer.stop(empty_pid)
    end

    test "returns consistent view list across multiple calls", %{pid: pid, views: views} do
      assert Manager.get_views(pid) == views
      assert Manager.get_views(pid) == views
      assert Manager.get_views(pid) == views
    end
  end

  describe "update_views/2" do
    setup do
      initial_views = [View.new("initial", "any", [], true)]
      {:ok, pid} = Manager.start_link(views: initial_views, name: nil)
      %{pid: pid, initial_views: initial_views}
    end

    test "updates views atomically", %{pid: pid} do
      new_views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false)
      ]

      assert Manager.update_views(pid, new_views) == :ok
      assert Manager.get_views(pid) == new_views
    end

    test "replaces all views with new list", %{pid: pid} do
      new_views = [View.new("replacement", "localnets", [], true)]

      assert Manager.update_views(pid, new_views) == :ok
      assert Manager.get_views(pid) == new_views
      assert length(Manager.get_views(pid)) == 1
    end

    test "accepts empty view list", %{pid: pid} do
      assert Manager.update_views(pid, []) == :ok
      assert Manager.get_views(pid) == []
    end

    test "rejects non-list input", %{pid: pid} do
      # Guard clause prevents non-list inputs - will raise FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        Manager.update_views(pid, %{})
      end

      assert_raise FunctionClauseError, fn ->
        Manager.update_views(pid, "not a list")
      end

      assert_raise FunctionClauseError, fn ->
        Manager.update_views(pid, nil)
      end
    end

    test "rejects list with non-View structs", %{pid: pid} do
      invalid_views = [
        View.new("valid", "any", [], true),
        %{not: "a view struct"}
      ]

      assert {:error, :invalid_view_type} = Manager.update_views(pid, invalid_views)

      # Original views should be unchanged
      assert length(Manager.get_views(pid)) == 1
    end

    test "rejects views with duplicate names", %{pid: pid} do
      duplicate_views = [
        View.new("duplicate", "any", [], true),
        View.new("duplicate", "localhost", [], false)
      ]

      assert {:error, {:duplicate_view_names, ["duplicate"]}} =
               Manager.update_views(pid, duplicate_views)

      # Original views should be unchanged
      assert length(Manager.get_views(pid)) == 1
    end

    test "allows multiple updates in sequence", %{pid: pid} do
      views1 = [View.new("first", "any", [], true)]
      views2 = [View.new("second", "localhost", [], true)]
      views3 = [View.new("third", "localnets", [], false)]

      assert Manager.update_views(pid, views1) == :ok
      assert Manager.get_views(pid) == views1

      assert Manager.update_views(pid, views2) == :ok
      assert Manager.get_views(pid) == views2

      assert Manager.update_views(pid, views3) == :ok
      assert Manager.get_views(pid) == views3
    end
  end

  describe "stats/1" do
    setup do
      initial_views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false)
      ]

      {:ok, pid} = Manager.start_link(views: initial_views, name: nil)
      %{pid: pid}
    end

    test "returns statistics map", %{pid: pid} do
      stats = Manager.stats(pid)

      assert is_map(stats)
      assert Map.has_key?(stats, :view_count)
      assert Map.has_key?(stats, :update_count)
      assert Map.has_key?(stats, :last_update)
      assert Map.has_key?(stats, :view_names)
    end

    test "reports correct view count", %{pid: pid} do
      stats = Manager.stats(pid)
      assert stats.view_count == 2
      assert stats.view_names == ["view1", "view2"]
    end

    test "tracks update count", %{pid: pid} do
      initial_stats = Manager.stats(pid)
      assert initial_stats.update_count == 0
      assert initial_stats.last_update == nil

      # Perform update
      new_views = [View.new("updated", "any", [], true)]
      Manager.update_views(pid, new_views)

      updated_stats = Manager.stats(pid)
      assert updated_stats.update_count == 1
      assert updated_stats.last_update != nil
      assert updated_stats.view_count == 1
    end

    test "increments update count on each update", %{pid: pid} do
      for i <- 1..5 do
        views = [View.new("view#{i}", "any", [], true)]
        Manager.update_views(pid, views)

        stats = Manager.stats(pid)
        assert stats.update_count == i
      end
    end

    test "does not increment update count on failed validation", %{pid: pid} do
      initial_stats = Manager.stats(pid)
      initial_count = initial_stats.update_count

      # Attempt invalid update
      Manager.update_views(pid, [%{invalid: true}])

      stats = Manager.stats(pid)
      assert stats.update_count == initial_count
    end
  end

  describe "match_client/2" do
    setup do
      views = [
        View.new("localhost", "localhost", [], true),
        View.new("internal", "localnets", [], true),
        View.new("external", "any", [], false)
      ]

      {:ok, pid} = Manager.start_link(views: views, name: nil)
      %{pid: pid}
    end

    test "matches localhost client to localhost view", %{pid: pid} do
      {:ok, view} = Manager.match_client(pid, {127, 0, 0, 1})
      assert view.name == "localhost"
    end

    test "matches private network client to internal view", %{pid: pid} do
      {:ok, view} = Manager.match_client(pid, {192, 168, 1, 100})
      assert view.name == "internal"
    end

    test "matches public IP to external view", %{pid: pid} do
      {:ok, view} = Manager.match_client(pid, {8, 8, 8, 8})
      assert view.name == "external"
    end

    test "returns error when no views match", %{pid: _pid} do
      # Create manager with only "localhost" view
      views = [View.new("localhost", "localhost", [], true)]
      {:ok, pid} = Manager.start_link(views: views, name: nil)

      # Public IP won't match localhost view
      assert {:error, :no_match} = Manager.match_client(pid, {8, 8, 8, 8})

      GenServer.stop(pid)
    end

    test "uses first-match-wins evaluation", %{pid: pid} do
      # localhost is first, so it should match before internal
      {:ok, view} = Manager.match_client(pid, {127, 0, 0, 1})
      assert view.name == "localhost"
    end
  end

  describe "concurrent access" do
    setup do
      views = [View.new("concurrent", "any", [], true)]
      {:ok, pid} = Manager.start_link(views: views, name: nil)
      %{pid: pid}
    end

    test "handles concurrent get_views calls", %{pid: pid} do
      # Spawn multiple processes reading views concurrently
      tasks =
        for _i <- 1..100 do
          Task.async(fn ->
            Manager.get_views(pid)
          end)
        end

      results = Task.await_many(tasks)

      # All results should be identical
      assert Enum.all?(results, fn views -> length(views) == 1 end)
    end

    test "handles concurrent updates", %{pid: pid} do
      # Spawn multiple processes updating views concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            views = [View.new("view#{i}", "any", [], true)]
            Manager.update_views(pid, views)
          end)
        end

      results = Task.await_many(tasks)

      # All updates should succeed
      assert Enum.all?(results, fn result -> result == :ok end)

      # Stats should show all 50 updates
      stats = Manager.stats(pid)
      assert stats.update_count == 50
    end

    test "concurrent reads during updates don't block", %{pid: pid} do
      # Start continuous readers
      reader_tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            for _j <- 1..10 do
              Manager.get_views(pid)
              Process.sleep(1)
            end
          end)
        end

      # Perform updates while readers are running
      for i <- 1..10 do
        views = [View.new("view#{i}", "any", [], true)]
        Manager.update_views(pid, views)
        Process.sleep(2)
      end

      # Wait for readers to complete
      Task.await_many(reader_tasks)

      # Final state should be consistent
      stats = Manager.stats(pid)
      assert stats.update_count == 10
    end
  end

  describe "change tracking" do
    setup do
      initial_views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false)
      ]

      {:ok, pid} = Manager.start_link(views: initial_views, name: nil)
      %{pid: pid}
    end

    test "detects added views", %{pid: pid} do
      new_views = [
        View.new("view1", "any", [], true),
        View.new("view2", "localhost", [], false),
        View.new("view3", "localnets", [], true)
      ]

      Manager.update_views(pid, new_views)

      stats = Manager.stats(pid)
      assert "view3" in stats.view_names
    end

    test "detects removed views", %{pid: pid} do
      new_views = [View.new("view1", "any", [], true)]

      Manager.update_views(pid, new_views)

      stats = Manager.stats(pid)
      assert stats.view_names == ["view1"]
      refute "view2" in stats.view_names
    end

    test "detects modified views", %{pid: pid} do
      # Same name but different configuration
      modified_views = [
        View.new("view1", "localhost", [], false),
        # Changed match_clients and recursion
        View.new("view2", "localhost", [], false)
      ]

      Manager.update_views(pid, modified_views)

      stats = Manager.stats(pid)
      assert stats.view_count == 2
      assert stats.update_count == 1
    end
  end

  describe "view validation edge cases" do
    setup do
      {:ok, pid} = Manager.start_link(name: nil)
      %{pid: pid}
    end

    test "accepts views with same ACL but different names", %{pid: pid} do
      views = [
        View.new("view1", "any", [], true),
        View.new("view2", "any", [], true)
      ]

      assert Manager.update_views(pid, views) == :ok
    end

    test "accepts views with same zones but different names", %{pid: pid} do
      views = [
        View.new("view1", "any", ["example.com"], true),
        View.new("view2", "localhost", ["example.com"], true)
      ]

      assert Manager.update_views(pid, views) == :ok
    end

    test "rejects mixed valid and invalid views", %{pid: pid} do
      invalid_views = [
        View.new("valid", "any", [], true),
        "not a view",
        View.new("also_valid", "localhost", [], false)
      ]

      assert {:error, :invalid_view_type} = Manager.update_views(pid, invalid_views)
      assert Manager.get_views(pid) == []
    end
  end

  describe "integration with View module" do
    setup do
      views = [
        View.new("test_view", "localnets", ["example.com", "test.com"], true)
      ]

      {:ok, pid} = Manager.start_link(views: views, name: nil)
      %{pid: pid}
    end

    test "returns views that work with View.matches?/2", %{pid: pid} do
      [view] = Manager.get_views(pid)

      assert View.matches?(view, {192, 168, 1, 100}) == true
      assert View.matches?(view, {8, 8, 8, 8}) == false
    end

    test "returns views that work with View.has_zone?/2", %{pid: pid} do
      [view] = Manager.get_views(pid)

      assert View.has_zone?(view, "example.com") == true
      assert View.has_zone?(view, "other.com") == false
    end
  end
end
