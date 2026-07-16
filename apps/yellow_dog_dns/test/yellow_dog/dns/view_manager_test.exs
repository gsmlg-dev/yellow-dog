defmodule YellowDog.Dns.ViewManagerTest.ChangingSupervisor do
  @moduledoc false

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def calls(pid), do: GenServer.call(pid, :calls)

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       children: Keyword.fetch!(options, :children),
       reported_active: Keyword.fetch!(options, :reported_active),
       calls: []
     }}
  end

  @impl GenServer
  def handle_call(:count_children, _from, state) do
    count = state.reported_active
    reply = [specs: count, active: count, supervisors: 0, workers: count]
    {:reply, reply, %{state | calls: [:count_children | state.calls]}}
  end

  def handle_call(:which_children, _from, state) do
    {:reply, state.children, %{state | calls: [:which_children | state.calls]}}
  end

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}
end

defmodule YellowDog.Dns.ViewManagerTest.ProbeView do
  @moduledoc false

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init(options), do: {:ok, Keyword.fetch!(options, :test_pid)}

  @impl GenServer
  def handle_call(message, _from, test_pid) do
    send(test_pid, {:probe_view_call, message})

    reply =
      case message do
        :get_name -> "probe"
        :get_priority -> 0
        :control_snapshot -> {:ok, %{match_clients: [], recursion: false}}
      end

    {:reply, reply, test_pid}
  end
end

defmodule YellowDog.Dns.ViewManagerTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.ViewManager.

  Tests cover:
  - DynamicSupervisor lifecycle (start_link)
  - View process management (start_view, stop_view, get_view)
  - View listing and statistics
  - Configuration updates
  - Priority-based routing
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ViewManagerTest.ChangingSupervisor
  alias YellowDog.Dns.ViewManagerTest.ProbeView

  # Start required registry before all tests
  setup_all do
    case Registry.start_link(keys: :unique, name: YellowDog.Dns.ViewRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Start a fresh ViewManager for each test
  setup do
    name = :"view_manager_test_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = ViewManager.start_link(name: name)

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
      name = :"vm_default_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = ViewManager.start_link(name: name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "starts with custom options" do
      name = :"vm_custom_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = ViewManager.start_link(name: name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop(pid)
    end
  end

  describe "start_view/2" do
    @tag :capture_log
    test "starts a view with keyword config", %{supervisor: supervisor} do
      view_name = "test_view_#{:rand.uniform(1_000_000)}"

      {:ok, view_pid} =
        ViewManager.start_view(
          supervisor,
          name: view_name,
          priority: 10,
          acl: :any
        )

      assert is_pid(view_pid)
      assert Process.alive?(view_pid)
    end

    @tag :capture_log
    test "starts a view with map config", %{supervisor: supervisor} do
      view_name = "map_view_#{:rand.uniform(1_000_000)}"

      {:ok, view_pid} =
        ViewManager.start_view(
          supervisor,
          %{name: view_name, priority: 20, acl: :any}
        )

      assert is_pid(view_pid)
      assert Process.alive?(view_pid)
    end

    @tag :capture_log
    test "starts multiple views", %{supervisor: supervisor} do
      view1_name = "multi1_#{:rand.uniform(1_000_000)}"
      view2_name = "multi2_#{:rand.uniform(1_000_000)}"

      {:ok, pid1} = ViewManager.start_view(supervisor, name: view1_name, priority: 10, acl: :any)
      {:ok, pid2} = ViewManager.start_view(supervisor, name: view2_name, priority: 20, acl: :any)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end

    @tag :capture_log
    test "returns error for duplicate view name", %{supervisor: supervisor} do
      view_name = "dup_#{:rand.uniform(1_000_000)}"

      {:ok, _pid1} = ViewManager.start_view(supervisor, name: view_name, priority: 10, acl: :any)

      {:error, {:already_started, _}} =
        ViewManager.start_view(supervisor, name: view_name, priority: 20, acl: :any)
    end
  end

  describe "get_view/2" do
    @tag :capture_log
    test "finds existing view", %{supervisor: supervisor} do
      view_name = "findme_#{:rand.uniform(1_000_000)}"

      {:ok, started_pid} =
        ViewManager.start_view(supervisor, name: view_name, priority: 10, acl: :any)

      {:ok, found_pid} = ViewManager.get_view(supervisor, view_name)

      assert found_pid == started_pid
    end

    @tag :capture_log
    test "returns error for non-existent view", %{supervisor: supervisor} do
      result = ViewManager.get_view(supervisor, "nonexistent_#{:rand.uniform(1_000_000)}")

      assert result == :error
    end
  end

  describe "stop_view/2" do
    @tag :capture_log
    test "stops existing view", %{supervisor: supervisor} do
      view_name = "stopme_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = ViewManager.start_view(supervisor, name: view_name, priority: 10, acl: :any)
      assert Process.alive?(pid)

      :ok = ViewManager.stop_view(supervisor, view_name)

      Process.sleep(10)
      refute Process.alive?(pid)
    end

    @tag :capture_log
    test "returns error for non-existent view", %{supervisor: supervisor} do
      result = ViewManager.stop_view(supervisor, "nonexistent_#{:rand.uniform(1_000_000)}")

      assert result == {:error, :not_found}
    end
  end

  describe "list_views/1" do
    @tag :capture_log
    test "returns empty list when no views", %{supervisor: supervisor} do
      views = ViewManager.list_views(supervisor)

      assert views == []
    end

    @tag :capture_log
    test "returns all views sorted by priority", %{supervisor: supervisor} do
      view1 = "list1_#{:rand.uniform(1_000_000)}"
      view2 = "list2_#{:rand.uniform(1_000_000)}"
      view3 = "list3_#{:rand.uniform(1_000_000)}"

      # Start in non-priority order
      {:ok, _} = ViewManager.start_view(supervisor, name: view2, priority: 20, acl: :any)
      {:ok, _} = ViewManager.start_view(supervisor, name: view1, priority: 10, acl: :any)
      {:ok, _} = ViewManager.start_view(supervisor, name: view3, priority: 30, acl: :any)

      views = ViewManager.list_views(supervisor)

      assert length(views) == 3

      # Should be sorted by priority
      priorities = Enum.map(views, fn {_name, _pid, priority} -> priority end)
      assert priorities == Enum.sort(priorities)
    end

    @tag :capture_log
    test "returns view tuples with name, pid, priority", %{supervisor: supervisor} do
      view_name = "tuple_#{:rand.uniform(1_000_000)}"

      {:ok, _} = ViewManager.start_view(supervisor, name: view_name, priority: 42, acl: :any)

      views = ViewManager.list_views(supervisor)

      assert length(views) == 1
      [{name, pid, priority}] = views
      assert name == view_name
      assert is_pid(pid)
      assert priority == 42
    end
  end

  describe "list_control_views/1" do
    @tag :capture_log
    test "returns canonical control fields without process identifiers", %{supervisor: supervisor} do
      view_name = "control_#{:rand.uniform(1_000_000)}"

      {:ok, _pid} =
        ViewManager.start_view(
          supervisor,
          name: view_name,
          priority: 10,
          acl: "localnets",
          recursion_enabled: true
        )

      assert {:ok,
              [
                %{
                  name: ^view_name,
                  match_clients: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
                  recursion: true
                }
              ]} = ViewManager.list_control_views(supervisor)
    end

    @tag :capture_log
    test "rejects a view whose ACL cannot be represented by match CIDRs", %{
      supervisor: supervisor
    } do
      {:ok, _pid} =
        ViewManager.start_view(
          supervisor,
          name: "mixed_#{:rand.uniform(1_000_000)}",
          priority: 10,
          acl: [{:allow, {10, 0, 0, 0}, 8}, {:deny, {10, 1, 0, 0}, 16}]
        )

      assert {:error, :unsupported_acl} = ViewManager.list_control_views(supervisor)
    end

    @tag :capture_log
    @tag timeout: 120_000
    test "rejects too many active views before calling each View", %{supervisor: supervisor} do
      suffix = :erlang.unique_integer([:positive])

      for index <- 0..1_000 do
        {:ok, _pid} =
          ViewManager.start_view(
            supervisor,
            name: "control_bound_#{suffix}_#{index}",
            priority: index,
            acl: :any
          )
      end

      assert {:error, :control_snapshot_too_large} =
               ViewManager.list_control_views(supervisor)
    end

    @tag :capture_log
    test "bounds and traverses one exact child snapshot when the child set changes" do
      probe = start_supervised!({ProbeView, test_pid: self()})

      children =
        [{:undefined, probe, :worker, [YellowDog.Dns.View]}] ++
          List.duplicate({:undefined, :restarting, :worker, [YellowDog.Dns.View]}, 1_000)

      supervisor =
        start_supervised!({ChangingSupervisor, children: children, reported_active: 1_000})

      assert {:error, :control_snapshot_too_large} =
               ViewManager.list_control_views(supervisor)

      assert ChangingSupervisor.calls(supervisor) == [:which_children]
      refute_receive {:probe_view_call, _message}
    end
  end

  describe "stats/1" do
    @tag :capture_log
    test "returns empty stats when no views", %{supervisor: supervisor} do
      stats = ViewManager.stats(supervisor)

      assert stats == %{view_count: 0, views: %{}}
    end

    @tag :capture_log
    test "returns stats for all views", %{supervisor: supervisor} do
      view1 = "stats1_#{:rand.uniform(1_000_000)}"
      view2 = "stats2_#{:rand.uniform(1_000_000)}"

      {:ok, _} = ViewManager.start_view(supervisor, name: view1, priority: 10, acl: :any)
      {:ok, _} = ViewManager.start_view(supervisor, name: view2, priority: 20, acl: :any)

      stats = ViewManager.stats(supervisor)

      assert stats.view_count == 2
      assert Map.has_key?(stats.views, view1)
      assert Map.has_key?(stats.views, view2)

      # Each view stats should include priority
      assert stats.views[view1].priority == 10
      assert stats.views[view2].priority == 20
    end
  end

  describe "update_views/2" do
    @tag :capture_log
    test "starts new views from config", %{supervisor: supervisor} do
      view_name = "new_#{:rand.uniform(1_000_000)}"

      configs = [
        %{name: view_name, priority: 10, acl: :any}
      ]

      :ok = ViewManager.update_views(supervisor, configs)

      views = ViewManager.list_views(supervisor)
      names = Enum.map(views, fn {name, _pid, _priority} -> name end)
      assert view_name in names
    end

    @tag :capture_log
    test "removes views not in config", %{supervisor: supervisor} do
      view1 = "keep_#{:rand.uniform(1_000_000)}"
      view2 = "remove_#{:rand.uniform(1_000_000)}"

      {:ok, _} = ViewManager.start_view(supervisor, name: view1, priority: 10, acl: :any)
      {:ok, _} = ViewManager.start_view(supervisor, name: view2, priority: 20, acl: :any)

      # Update with only view1
      configs = [%{name: view1, priority: 10, acl: :any}]
      :ok = ViewManager.update_views(supervisor, configs)

      views = ViewManager.list_views(supervisor)
      names = Enum.map(views, fn {name, _pid, _priority} -> name end)
      assert view1 in names
      refute view2 in names
    end

    @tag :capture_log
    test "does not remove default view", %{supervisor: supervisor} do
      # Start default view first
      {:ok, _} = ViewManager.start_view(supervisor, name: "default", priority: 9999, acl: :any)

      # Update with empty config
      :ok = ViewManager.update_views(supervisor, [])

      views = ViewManager.list_views(supervisor)
      names = Enum.map(views, fn {name, _pid, _priority} -> name end)
      assert "default" in names
    end

    @tag :capture_log
    test "updates existing view config", %{supervisor: supervisor} do
      view_name = "update_#{:rand.uniform(1_000_000)}"

      {:ok, _} = ViewManager.start_view(supervisor, name: view_name, priority: 10, acl: :any)

      # Update with new priority
      configs = [%{name: view_name, priority: 99, acl: :any}]
      :ok = ViewManager.update_views(supervisor, configs)

      views = ViewManager.list_views(supervisor)
      {_name, _pid, priority} = Enum.find(views, fn {n, _, _} -> n == view_name end)
      assert priority == 99
    end
  end

  describe "priority-based ordering" do
    @tag :capture_log
    test "views are ordered by priority ascending", %{supervisor: supervisor} do
      # Create views with different priorities
      for {name_suffix, priority} <- [{"high", 100}, {"low", 1}, {"medium", 50}] do
        view_name = "prio_#{name_suffix}_#{:rand.uniform(1_000_000)}"

        {:ok, _} =
          ViewManager.start_view(supervisor, name: view_name, priority: priority, acl: :any)
      end

      views = ViewManager.list_views(supervisor)
      priorities = Enum.map(views, fn {_name, _pid, priority} -> priority end)

      assert priorities == Enum.sort(priorities)
    end
  end

  describe "concurrent operations" do
    @tag :capture_log
    test "handles concurrent view starts", %{supervisor: supervisor} do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            view_name = "concurrent_#{i}_#{:rand.uniform(1_000_000)}"
            ViewManager.start_view(supervisor, name: view_name, priority: i * 10, acl: :any)
          end)
        end

      results = Task.await_many(tasks, 10000)

      # All should succeed
      for result <- results do
        assert {:ok, pid} = result
        assert is_pid(pid)
      end

      views = ViewManager.list_views(supervisor)
      assert length(views) == 5
    end

    @tag :capture_log
    test "handles concurrent list operations", %{supervisor: supervisor} do
      # Start some views first
      for i <- 1..3 do
        view_name = "listtest_#{i}_#{:rand.uniform(1_000_000)}"
        ViewManager.start_view(supervisor, name: view_name, priority: i * 10, acl: :any)
      end

      # Concurrent list operations
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ViewManager.list_views(supervisor)
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
    test "handles stop of non-existent view gracefully", %{supervisor: supervisor} do
      result = ViewManager.stop_view(supervisor, "does_not_exist_#{:rand.uniform(1_000_000)}")

      assert result == {:error, :not_found}
    end

    @tag :capture_log
    test "handles get of non-existent view gracefully", %{supervisor: supervisor} do
      result = ViewManager.get_view(supervisor, "does_not_exist_#{:rand.uniform(1_000_000)}")

      assert result == :error
    end
  end

  describe "view with ACL configurations" do
    @tag :capture_log
    test "starts view with :any ACL", %{supervisor: supervisor} do
      view_name = "any_acl_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = ViewManager.start_view(supervisor, name: view_name, priority: 10, acl: :any)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "starts view with network ACL", %{supervisor: supervisor} do
      view_name = "net_acl_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        ViewManager.start_view(
          supervisor,
          name: view_name,
          priority: 10,
          acl: [{:allow, {10, 0, 0, 0}, 8}]
        )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "starts view with string ACL reference", %{supervisor: supervisor} do
      view_name = "str_acl_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        ViewManager.start_view(
          supervisor,
          name: view_name,
          priority: 10,
          acl: "localnets"
        )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
