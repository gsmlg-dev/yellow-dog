defmodule YellowDog.Console.LogBroadcasterTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.LogBroadcaster.

  Tests cover:
  - Module structure and exports
  - GenServer lifecycle
  - Telemetry attachment/detachment
  - PubSub broadcasting
  - Log event handling
  """
  use ExUnit.Case, async: false

  alias YellowDog.Console.LogBroadcaster

  # Helper to safely stop LogBroadcaster
  defp safe_stop_broadcaster do
    try do
      case Process.whereis(LogBroadcaster) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 1000)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(50)
  end

  # Helper to start fresh broadcaster
  defp start_fresh_broadcaster do
    safe_stop_broadcaster()
    {:ok, pid} = LogBroadcaster.start_link([])
    pid
  end

  setup do
    safe_stop_broadcaster()
    on_exit(fn -> safe_stop_broadcaster() end)
    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(LogBroadcaster)
    end

    test "uses GenServer behaviour" do
      Code.ensure_loaded!(LogBroadcaster)
      behaviours = LogBroadcaster.__info__(:attributes)[:behaviour] || []
      assert GenServer in behaviours
    end

    test "exports start_link/0" do
      Code.ensure_loaded!(LogBroadcaster)
      assert Kernel.function_exported?(LogBroadcaster, :start_link, 0)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(LogBroadcaster)
      assert Kernel.function_exported?(LogBroadcaster, :start_link, 1)
    end

    test "exports topic/0" do
      Code.ensure_loaded!(LogBroadcaster)
      assert Kernel.function_exported?(LogBroadcaster, :topic, 0)
    end

    test "exports handle_log_event/4" do
      Code.ensure_loaded!(LogBroadcaster)
      assert Kernel.function_exported?(LogBroadcaster, :handle_log_event, 4)
    end
  end

  describe "topic/0" do
    test "returns the PubSub topic" do
      topic = LogBroadcaster.topic()

      assert is_binary(topic)
      assert topic == "logs:stream"
    end
  end

  describe "start_link/1" do
    test "starts the GenServer" do
      {:ok, pid} = LogBroadcaster.start_link([])

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers with module name" do
      {:ok, pid} = LogBroadcaster.start_link([])

      assert Process.whereis(LogBroadcaster) == pid
    end

    test "returns already_started error if already running" do
      # First ensure we have a fresh start
      safe_stop_broadcaster()

      {:ok, _pid} = LogBroadcaster.start_link([])

      result = LogBroadcaster.start_link([])

      assert {:error, {:already_started, _}} = result
    end
  end

  describe "telemetry attachment" do
    test "attaches telemetry handlers on init" do
      _pid = start_fresh_broadcaster()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :info])

      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to debug events" do
      _pid = start_fresh_broadcaster()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :debug])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to info events" do
      _pid = start_fresh_broadcaster()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to warning events" do
      _pid = start_fresh_broadcaster()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :warning])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to error events" do
      _pid = start_fresh_broadcaster()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :error])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "detaches telemetry handlers on terminate" do
      pid = start_fresh_broadcaster()

      # Verify handlers are attached
      handlers_before = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids_before = Enum.map(handlers_before, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids_before

      # Stop the broadcaster
      GenServer.stop(pid)
      Process.sleep(50)

      # Verify handlers are detached
      handlers_after = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids_after = Enum.map(handlers_after, & &1.id)
      refute "yellow-dog-log-broadcaster" in handler_ids_after
    end
  end

  describe "handle_log_event/4" do
    setup do
      # Start PubSub if not already running (needed for tests)
      case Process.whereis(YellowDog.Console.PubSub) do
        nil ->
          {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: YellowDog.Console.PubSub)

        _ ->
          :ok
      end

      # Ensure fresh broadcaster state
      safe_stop_broadcaster()

      :ok
    end

    test "extracts level from event path" do
      # Test with info level
      event = [:yellow_dog, :log, :info]

      # This will try to broadcast, but we're testing the level extraction
      # The function should not crash
      LogBroadcaster.handle_log_event(event, %{}, %{}, %{})
    end

    test "extracts level from error event" do
      event = [:yellow_dog, :log, :error]

      # Should not crash
      LogBroadcaster.handle_log_event(event, %{}, %{}, %{})
    end

    test "broadcasts to PubSub topic when broadcaster is started" do
      # Subscribe to the topic
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      {:ok, _pid} = LogBroadcaster.start_link([])

      # Emit a telemetry event
      :telemetry.execute(
        [:yellow_dog, :log, :info],
        %{count: 1},
        %{message: "Test log message", source: __MODULE__}
      )

      # Should receive the broadcast
      assert_receive {:log_event, :info, %{count: 1}, %{message: "Test log message"}}, 1000
    end

    test "broadcasts debug events" do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      {:ok, _pid} = LogBroadcaster.start_link([])

      :telemetry.execute(
        [:yellow_dog, :log, :debug],
        %{count: 1},
        %{message: "Debug message"}
      )

      assert_receive {:log_event, :debug, _, _}, 1000
    end

    test "broadcasts warning events" do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      {:ok, _pid} = LogBroadcaster.start_link([])

      :telemetry.execute(
        [:yellow_dog, :log, :warning],
        %{count: 1},
        %{message: "Warning message"}
      )

      assert_receive {:log_event, :warning, _, _}, 1000
    end

    test "broadcasts error events" do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      {:ok, _pid} = LogBroadcaster.start_link([])

      :telemetry.execute(
        [:yellow_dog, :log, :error],
        %{count: 1},
        %{message: "Error message"}
      )

      assert_receive {:log_event, :error, _, _}, 1000
    end
  end

  describe "GenServer callbacks" do
    test "init returns ok with empty state" do
      pid = start_fresh_broadcaster()

      # Process should be alive and responsive
      assert Process.alive?(pid)
    end

    test "terminate is called on stop" do
      pid = start_fresh_broadcaster()

      # Stop should succeed
      :ok = GenServer.stop(pid)

      refute Process.alive?(pid)
    end
  end
end
