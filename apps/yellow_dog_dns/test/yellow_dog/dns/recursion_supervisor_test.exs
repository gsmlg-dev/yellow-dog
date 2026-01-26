defmodule YellowDog.Dns.RecursionSupervisorTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.RecursionSupervisor.

  Tests cover:
  - Supervisor lifecycle
  - Configuration management
  - Statistics reporting
  - Worker spawning
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RecursionSupervisor
  alias DNS.Message
  alias DNS.Message.RCode

  describe "start_link/1" do
    @tag :capture_log
    test "starts with required view_name" do
      view_name = "test_sup_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "starts with custom max_children" do
      view_name = "test_sup_max_#{:rand.uniform(1_000_000)}"
      max_children = 25

      {:ok, pid} =
        RecursionSupervisor.start_link(view_name: view_name, max_children: max_children)

      stats = RecursionSupervisor.stats(view_name)
      assert stats.max_children == max_children

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "starts with custom query_timeout" do
      view_name = "test_sup_timeout_#{:rand.uniform(1_000_000)}"
      query_timeout = 10_000

      {:ok, pid} =
        RecursionSupervisor.start_link(view_name: view_name, query_timeout: query_timeout)

      stats = RecursionSupervisor.stats(view_name)
      assert stats.query_timeout == query_timeout

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "fails to start when view_name is missing" do
      # The error is raised in init/1, which causes start_link to return an error
      Process.flag(:trap_exit, true)
      result = RecursionSupervisor.start_link([])
      assert {:error, _reason} = result
    end
  end

  describe "stats/1" do
    @tag :capture_log
    test "returns stats for running supervisor" do
      view_name = "test_stats_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      stats = RecursionSupervisor.stats(view_name)

      assert stats.view_name == view_name
      assert stats.max_children == 100
      assert stats.active_workers == 0
      assert stats.query_timeout == 5_000

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "returns error for non-existent supervisor" do
      stats = RecursionSupervisor.stats("nonexistent_view_#{:rand.uniform(1_000_000)}")
      assert stats == %{error: :not_running}
    end
  end

  describe "resolve/2" do
    @tag :capture_log
    test "returns error for non-existent view" do
      result = RecursionSupervisor.resolve("nonexistent_view_#{:rand.uniform(1_000_000)}", build_empty_query())
      assert {:error, :not_found} = result
    end

    @tag :capture_log
    test "returns format_error for empty query" do
      view_name = "test_resolve_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      result = RecursionSupervisor.resolve(view_name, build_empty_query())
      assert {:error, :format_error} = result

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "spawns workers for resolution" do
      view_name = "test_workers_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      # Start multiple concurrent resolves (they'll fail fast with format_error)
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            RecursionSupervisor.resolve(view_name, build_empty_query())
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert {:error, :format_error} = result
      end

      Supervisor.stop(pid)
    end
  end

  describe "supervisor children" do
    @tag :capture_log
    test "starts config agent as child" do
      view_name = "test_children_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      # Config agent should be named
      config_agent = :"recursion_config_#{view_name}"
      agent_pid = Process.whereis(config_agent)
      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      Supervisor.stop(pid)
    end

    @tag :capture_log
    test "starts task supervisor as child" do
      view_name = "test_task_sup_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = RecursionSupervisor.start_link(view_name: view_name)

      # Task supervisor should be named
      task_sup = :"recursion_tasks_#{view_name}"
      task_sup_pid = Process.whereis(task_sup)
      assert is_pid(task_sup_pid)
      assert Process.alive?(task_sup_pid)

      Supervisor.stop(pid)
    end
  end

  # Helper functions

  defp build_empty_query do
    %Message{
      header: %DNS.Message.Header{
        id: :rand.uniform(65535),
        qr: 0,
        opcode: :query,
        rd: 1,
        rcode: RCode.no_error(),
        qdcount: 0
      },
      qdlist: [],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end
end
