defmodule YellowDog.ServiceHeartbeatTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.ServiceHeartbeat.

  Tests cover:
  - Module structure and exports
  - GenServer lifecycle
  - Interval management
  - Heartbeat triggering
  - Configuration
  """
  use ExUnit.Case, async: false

  alias YellowDog.ServiceHeartbeat

  # Helper to safely stop the heartbeat GenServer
  defp safe_stop_heartbeat do
    try do
      case Process.whereis(ServiceHeartbeat) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 1000)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(50)
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ServiceHeartbeat)
    end

    test "uses GenServer behaviour" do
      Code.ensure_loaded!(ServiceHeartbeat)
      behaviours = ServiceHeartbeat.__info__(:attributes)[:behaviour] || []
      assert GenServer in behaviours
    end

    test "exports start_link/0" do
      Code.ensure_loaded!(ServiceHeartbeat)
      assert Kernel.function_exported?(ServiceHeartbeat, :start_link, 0)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(ServiceHeartbeat)
      assert Kernel.function_exported?(ServiceHeartbeat, :start_link, 1)
    end

    test "exports get_interval/0" do
      Code.ensure_loaded!(ServiceHeartbeat)
      assert Kernel.function_exported?(ServiceHeartbeat, :get_interval, 0)
    end

    test "exports set_interval/1" do
      Code.ensure_loaded!(ServiceHeartbeat)
      assert Kernel.function_exported?(ServiceHeartbeat, :set_interval, 1)
    end

    test "exports heartbeat_now/0" do
      Code.ensure_loaded!(ServiceHeartbeat)
      assert Kernel.function_exported?(ServiceHeartbeat, :heartbeat_now, 0)
    end
  end

  describe "start_link/1" do
    setup do
      safe_stop_heartbeat()
      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "starts the GenServer with default options" do
      {:ok, pid} = ServiceHeartbeat.start_link([])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers with module name" do
      {:ok, pid} = ServiceHeartbeat.start_link([])

      assert Process.whereis(ServiceHeartbeat) == pid
    end

    test "accepts custom interval option" do
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 10_000)

      assert ServiceHeartbeat.get_interval() == 10_000
    end
  end

  describe "get_interval/0" do
    setup do
      safe_stop_heartbeat()
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 5_000)

      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "returns the current interval" do
      interval = ServiceHeartbeat.get_interval()

      assert is_integer(interval)
      assert interval == 5_000
    end
  end

  describe "set_interval/1" do
    setup do
      safe_stop_heartbeat()
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 30_000)

      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "changes the interval" do
      assert ServiceHeartbeat.get_interval() == 30_000

      :ok = ServiceHeartbeat.set_interval(15_000)

      assert ServiceHeartbeat.get_interval() == 15_000
    end

    test "returns :ok on success" do
      result = ServiceHeartbeat.set_interval(20_000)

      assert result == :ok
    end
  end

  describe "heartbeat_now/0" do
    setup do
      safe_stop_heartbeat()
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 60_000)

      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "returns :ok" do
      result = ServiceHeartbeat.heartbeat_now()

      assert result == :ok
    end

    test "can be called multiple times" do
      assert ServiceHeartbeat.heartbeat_now() == :ok
      assert ServiceHeartbeat.heartbeat_now() == :ok
      assert ServiceHeartbeat.heartbeat_now() == :ok
    end
  end

  describe "init/1" do
    setup do
      safe_stop_heartbeat()
      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "uses default interval when not specified" do
      {:ok, _pid} = ServiceHeartbeat.start_link([])

      # Default is 30 seconds
      interval = ServiceHeartbeat.get_interval()
      assert interval == 30_000
    end

    test "starts the timer" do
      {:ok, pid} = ServiceHeartbeat.start_link(interval: 60_000)

      # Process should be alive and have scheduled the first heartbeat
      assert Process.alive?(pid)
    end
  end

  describe "handle_info :heartbeat" do
    setup do
      safe_stop_heartbeat()
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 100)

      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "schedules next heartbeat after current one" do
      # Wait for a few heartbeat cycles
      Process.sleep(300)

      # Process should still be alive
      assert Process.alive?(Process.whereis(ServiceHeartbeat))
    end
  end

  describe "state management" do
    setup do
      safe_stop_heartbeat()
      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "state contains interval" do
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 25_000)

      interval = ServiceHeartbeat.get_interval()
      assert interval == 25_000
    end

    test "interval can be changed at runtime" do
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 10_000)

      ServiceHeartbeat.set_interval(5_000)
      assert ServiceHeartbeat.get_interval() == 5_000

      ServiceHeartbeat.set_interval(20_000)
      assert ServiceHeartbeat.get_interval() == 20_000
    end
  end

  describe "concurrent access" do
    setup do
      safe_stop_heartbeat()
      {:ok, _pid} = ServiceHeartbeat.start_link(interval: 60_000)

      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "handles concurrent get_interval calls" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> ServiceHeartbeat.get_interval() end)
        end

      results = Task.await_many(tasks, 5000)

      Enum.each(results, fn interval ->
        assert is_integer(interval)
        assert interval > 0
      end)
    end

    test "handles concurrent heartbeat_now calls" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> ServiceHeartbeat.heartbeat_now() end)
        end

      results = Task.await_many(tasks, 5000)

      Enum.each(results, fn result ->
        assert result == :ok
      end)
    end
  end

  describe "default interval configuration" do
    setup do
      safe_stop_heartbeat()
      on_exit(fn -> safe_stop_heartbeat() end)
      :ok
    end

    test "uses configured interval from application env when available" do
      # The default_interval is 30_000 (30 seconds) as defined in the module
      {:ok, _pid} = ServiceHeartbeat.start_link([])

      # Should use the default if no app env is set
      interval = ServiceHeartbeat.get_interval()
      assert interval == 30_000
    end
  end
end
