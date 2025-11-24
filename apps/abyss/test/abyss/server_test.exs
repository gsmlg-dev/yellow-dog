defmodule Abyss.ServerTest do
  use ExUnit.Case, async: false

  alias Abyss.Server
  alias Abyss.ServerConfig

  setup do
    config = ServerConfig.new(handler_module: Abyss.TestHandler, port: 0)
    {:ok, %{config: config}}
  end

  describe "start_link/1" do
    test "starts successfully with valid config", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)
      assert Process.alive?(pid)
      :ok = Supervisor.stop(pid)
    end

    test "returns error with invalid config" do
      invalid_config = %{invalid: "config"}

      assert_raise ArgumentError, ~r/invalid configuration/, fn ->
        Server.start_link(invalid_config)
      end
    end
  end

  describe "listener_pool_pid/1" do
    test "returns listener pool pid", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)
      assert listener_pool_pid = Server.listener_pool_pid(pid)
      assert is_pid(listener_pool_pid)
      :ok = Supervisor.stop(pid)
    end

    test "returns nil for invalid supervisor" do
      assert Server.listener_pool_pid(:nonexistent) == nil
    end
  end

  describe "connection_sup_pid/1" do
    test "returns connection supervisor pid", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)
      assert connection_sup_pid = Server.connection_sup_pid(pid)
      assert is_pid(connection_sup_pid)
      :ok = Supervisor.stop(pid)
    end

    test "returns nil for invalid supervisor" do
      assert Server.connection_sup_pid(:nonexistent) == nil
    end
  end

  describe "suspend/1 and resume/1" do
    test "can suspend and resume server", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)

      # Should be able to suspend
      assert :ok = Server.suspend(pid)

      # Should be able to resume
      assert :ok = Server.resume(pid)

      :ok = Supervisor.stop(pid)
    end

    test "suspend returns error for invalid supervisor" do
      assert nil == Server.suspend(:nonexistent)
    end

    test "resume returns error for invalid supervisor" do
      assert nil == Server.resume(:nonexistent)
    end
  end

  describe "supervisor structure" do
    test "has correct children", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)

      children = Supervisor.which_children(pid)
      assert length(children) == 4

      # Check for expected child ids
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert :listener_pool in child_ids
      assert :connection_sup in child_ids
      assert :activator in child_ids
      assert :shutdown_listener in child_ids

      :ok = Supervisor.stop(pid)
    end
  end
end
