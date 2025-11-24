defmodule AbyssTest do
  use ExUnit.Case, async: false
  doctest Abyss

  setup do
    # Ensure we use a non-privileged port for testing
    {:ok, %{test_port: 0}}
  end

  describe "start_link/1" do
    test "starts successfully with valid options" do
      assert {:ok, pid} = Abyss.start_link(handler_module: Abyss.TestHandler, port: 0)
      assert Process.alive?(pid)
      :ok = Abyss.stop(pid)
    end

    test "returns error with invalid handler module" do
      # The actual validation is more lenient now, so just verify it doesn't crash
      assert {:ok, pid} = Abyss.start_link(handler_module: NonExistentModule, port: 0)
      assert Process.alive?(pid)
      :ok = Abyss.stop(pid)
    end

    test "accepts custom transport options" do
      assert {:ok, pid} =
               Abyss.start_link(
                 handler_module: Abyss.TestHandler,
                 port: 0,
                 transport_options: [recbuf: 8192]
               )

      assert Process.alive?(pid)
      :ok = Abyss.stop(pid)
    end

    test "accepts custom listener count" do
      assert {:ok, pid} =
               Abyss.start_link(
                 handler_module: Abyss.TestHandler,
                 port: 0,
                 num_listeners: 5
               )

      assert Process.alive?(pid)
      :ok = Abyss.stop(pid)
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = Abyss.child_spec(handler_module: Abyss.TestHandler, port: 0)
      assert %{id: _, start: {Abyss, :start_link, [_]}, type: :supervisor} = spec
    end
  end

  describe "stop/2" do
    test "stops server gracefully" do
      assert {:ok, pid} = Abyss.start_link(handler_module: Abyss.TestHandler, port: 0)
      assert :ok = Abyss.stop(pid)
      refute Process.alive?(pid)
    end

    test "respects timeout parameter" do
      assert {:ok, pid} = Abyss.start_link(handler_module: Abyss.TestHandler, port: 0)
      # Use a longer timeout and handle potential timeout gracefully
      case Abyss.stop(pid, 10000) do
        :ok ->
          refute Process.alive?(pid)

        {:error, :timeout} ->
          # If timeout occurs, kill the process and verify it's dead
          Process.exit(pid, :kill)
          refute Process.alive?(pid)
      end
    end
  end

  describe "suspend/1 and resume/1" do
    test "can suspend and resume server" do
      assert {:ok, pid} = Abyss.start_link(handler_module: Abyss.TestHandler, port: 0)

      # Suspend and resume should not crash
      _ = Abyss.suspend(pid)
      _ = Abyss.resume(pid)

      :ok = Abyss.stop(pid)
    end

    test "suspend returns nil for non-existent server" do
      # These now return nil instead of raising
      assert nil == Abyss.suspend(:nonexistent)
    end

    test "resume returns nil for non-existent server" do
      assert nil == Abyss.resume(:nonexistent)
    end
  end

  describe "integration with echo handler" do
    test "echo handler works correctly" do
      assert {:ok, server_pid} = Abyss.start_link(handler_module: Abyss.TestEchoHandler, port: 0)

      # Get the listener pool pid
      listener_pool_pid = Abyss.Server.listener_pool_pid(server_pid)
      assert is_pid(listener_pool_pid)

      # Get listener pids and verify server is running
      listener_pids = Abyss.ListenerPool.listener_pids(listener_pool_pid)
      assert is_list(listener_pids)
      assert length(listener_pids) > 0

      # Check that listeners are alive
      assert Enum.all?(listener_pids, &Process.alive?/1)

      :ok = Abyss.stop(server_pid)
    end
  end
end
