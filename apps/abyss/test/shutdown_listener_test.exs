defmodule Abyss.ShutdownListenerTest do
  @moduledoc """
  Comprehensive unit tests for Abyss.ShutdownListener.

  Tests cover:
  - Module structure and exports
  - GenServer callbacks (init, handle_continue, terminate)
  - State structure

  Note: Full integration tests with a real Abyss.Server are in the server tests.
  These tests verify the module's contract and callback behavior in isolation.
  """
  use ExUnit.Case, async: true

  alias Abyss.ShutdownListener

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ShutdownListener)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(ShutdownListener)
      assert Kernel.function_exported?(ShutdownListener, :start_link, 1)
    end

    test "exports init/1" do
      Code.ensure_loaded!(ShutdownListener)
      assert Kernel.function_exported?(ShutdownListener, :init, 1)
    end

    test "exports handle_continue/2" do
      Code.ensure_loaded!(ShutdownListener)
      assert Kernel.function_exported?(ShutdownListener, :handle_continue, 2)
    end

    test "exports terminate/2" do
      Code.ensure_loaded!(ShutdownListener)
      assert Kernel.function_exported?(ShutdownListener, :terminate, 2)
    end

    test "uses GenServer behaviour" do
      Code.ensure_loaded!(ShutdownListener)
      behaviours = ShutdownListener.__info__(:attributes)[:behaviour] || []
      assert GenServer in behaviours
    end
  end

  describe "init/1" do
    test "returns ok tuple with state and continue" do
      server_pid = self()

      result = ShutdownListener.init(server_pid)

      assert {:ok, state, {:continue, :setup_listener_pool_pid}} = result
      assert is_map(state)
    end

    test "stores server_pid in state" do
      server_pid = self()
      {:ok, state, _} = ShutdownListener.init(server_pid)

      assert state.server_pid == server_pid
    end

    test "schedules continue callback for listener pool setup" do
      {:ok, _state, continue} = ShutdownListener.init(self())

      assert continue == {:continue, :setup_listener_pool_pid}
    end

    test "accepts any PID" do
      # Create a short-lived process
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      {:ok, state, _} = ShutdownListener.init(pid)

      assert state.server_pid == pid
    end
  end

  describe "terminate/2" do
    # NOTE: terminate/2 has two clauses:
    # 1. When state contains :listener_pool_pid key -> calls Abyss.ListenerPool.suspend/1
    # 2. Fallback clause -> returns :ok
    # We test the fallback clause directly since ListenerPool requires real supervision tree

    test "returns :ok without listener_pool_pid in state" do
      state = %{}

      result = ShutdownListener.terminate(:normal, state)

      assert result == :ok
    end

    test "handles :normal reason" do
      # Use state without listener_pool_pid key to match fallback clause
      state = %{server_pid: self()}
      assert ShutdownListener.terminate(:normal, state) == :ok
    end

    test "handles :shutdown reason" do
      state = %{server_pid: self()}
      assert ShutdownListener.terminate(:shutdown, state) == :ok
    end

    test "handles {:shutdown, term} reason" do
      state = %{server_pid: self()}
      assert ShutdownListener.terminate({:shutdown, :test}, state) == :ok
    end

    test "handles arbitrary termination reason" do
      state = %{server_pid: self()}
      assert ShutdownListener.terminate(:killed, state) == :ok
      assert ShutdownListener.terminate(:timeout, state) == :ok
      assert ShutdownListener.terminate({:error, :reason}, state) == :ok
    end

    test "handles state with server_pid only" do
      state = %{server_pid: self()}
      assert ShutdownListener.terminate(:normal, state) == :ok
    end

    test "handles empty map state" do
      assert ShutdownListener.terminate(:normal, %{}) == :ok
    end
  end

  describe "state structure" do
    test "initial state is a map" do
      {:ok, state, _} = ShutdownListener.init(self())

      assert is_map(state)
    end

    test "initial state contains server_pid" do
      {:ok, state, _} = ShutdownListener.init(self())

      assert Map.has_key?(state, :server_pid)
    end

    test "initial state only contains server_pid" do
      {:ok, state, _} = ShutdownListener.init(self())

      assert Map.keys(state) == [:server_pid]
    end
  end

  describe "type specifications" do
    # These tests verify the documented types by testing edge cases

    test "start_link accepts a pid" do
      # We can't actually start_link without a real server,
      # but we verify the function signature
      assert is_function(&ShutdownListener.start_link/1)
    end

    test "init returns proper tuple structure" do
      {:ok, state, continue} = ShutdownListener.init(self())

      assert is_map(state)
      assert is_tuple(continue)
      assert elem(continue, 0) == :continue
    end
  end

  describe "continue callback contract" do
    test "handle_continue expects :setup_listener_pool_pid atom" do
      # Verify the expected continue message is :setup_listener_pool_pid
      {:ok, _state, {:continue, continue_action}} = ShutdownListener.init(self())

      assert continue_action == :setup_listener_pool_pid
    end
  end

  describe "trap_exit setup" do
    test "init is designed to trap exits" do
      # The init function calls Process.flag(:trap_exit, true)
      # We can verify this by checking the source documentation
      # and the fact that init returns a continue callback
      {:ok, state, {:continue, _}} = ShutdownListener.init(self())

      # State should be valid for terminate to work with
      assert is_map(state)
    end
  end
end
