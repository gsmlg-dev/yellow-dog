defmodule Abyss.ListenerPoolTest do
  use ExUnit.Case, async: false

  alias Abyss.ListenerPool
  alias Abyss.ServerConfig

  setup do
    config = ServerConfig.new(handler_module: Abyss.TestHandler, port: 0)
    {:ok, %{config: config}}
  end

  describe "start_link/1" do
    test "starts successfully with valid config", %{config: config} do
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})
      assert Process.alive?(pid)
      :ok = Supervisor.stop(pid)
    end

    test "creates correct number of listeners for non-broadcast", %{config: config} do
      config = %{config | num_listeners: 3}
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})

      listener_pids = ListenerPool.listener_pids(pid)
      assert length(listener_pids) == 3
      assert Enum.all?(listener_pids, &Process.alive?/1)

      :ok = Supervisor.stop(pid)
    end

    test "creates single listener for broadcast", %{config: config} do
      config = %{config | broadcast: true, port: 0}
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})

      listener_pids = ListenerPool.listener_pids(pid)
      assert length(listener_pids) == 1
      assert Enum.all?(listener_pids, &Process.alive?/1)

      :ok = Supervisor.stop(pid)
    end
  end

  describe "listener_pids/1" do
    test "returns list of listener pids", %{config: config} do
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})

      listener_pids = ListenerPool.listener_pids(pid)
      assert is_list(listener_pids)
      assert length(listener_pids) > 0
      assert Enum.all?(listener_pids, &Process.alive?/1)

      :ok = Supervisor.stop(pid)
    end

    test "returns empty list for invalid pool" do
      assert ListenerPool.listener_pids(:nonexistent) == []
    end
  end

  describe "suspend/1 and resume/1" do
    test "can suspend and resume listeners", %{config: config} do
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})

      # Suspend should return :ok
      assert :ok = ListenerPool.suspend(pid)

      # Resume should return :ok
      assert :ok = ListenerPool.resume(pid)

      :ok = Supervisor.stop(pid)
    end

    test "suspend returns error for invalid pool" do
      assert :error = ListenerPool.suspend(:nonexistent)
    end

    test "resume returns error for invalid pool" do
      assert :error = ListenerPool.resume(:nonexistent)
    end
  end

  describe "start_listening/1" do
    test "starts all listeners", %{config: config} do
      server_pid = self()
      assert {:ok, pid} = ListenerPool.start_link({server_pid, config})

      # Should not crash
      assert :ok = ListenerPool.start_listening(pid)

      :ok = Supervisor.stop(pid)
    end
  end
end
