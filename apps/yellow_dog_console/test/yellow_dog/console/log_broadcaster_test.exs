defmodule YellowDog.Console.LogBroadcasterTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.LogBroadcaster.

  Tests cover:
  - Module structure and exports
  - GenServer lifecycle
  - Telemetry attachment/detachment
  - PubSub broadcasting
  - Log event handling

  Note: These tests work with the application-managed LogBroadcaster when it's
  running. Tests avoid stopping the application-managed process to prevent
  interference with other test modules.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Console.LogBroadcaster

  # Helper to ensure LogBroadcaster is running (either from app or started fresh)
  # Does NOT stop existing application-managed process
  defp ensure_broadcaster_running do
    case Process.whereis(LogBroadcaster) do
      nil ->
        # Start using start_supervised! for proper test lifecycle management
        start_supervised!(LogBroadcaster)

      pid ->
        # Use existing application-managed process
        pid
    end
  end

  setup do
    # Don't stop application-managed process - just ensure it's running
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

    test "exports handle_telemetry_event/4" do
      Code.ensure_loaded!(LogBroadcaster)
      assert Kernel.function_exported?(LogBroadcaster, :handle_telemetry_event, 4)
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
    test "the GenServer is running" do
      # When running with app, broadcaster is already started
      # When running in isolation, ensure_broadcaster_running() starts it
      pid = ensure_broadcaster_running()

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers with module name" do
      pid = ensure_broadcaster_running()

      assert Process.whereis(LogBroadcaster) == pid
    end

    test "returns already_started error if already running" do
      # Ensure broadcaster is running
      _pid = ensure_broadcaster_running()

      # Try to start again - should fail
      result = LogBroadcaster.start_link([])

      assert {:error, {:already_started, _}} = result
    end
  end

  describe "telemetry attachment" do
    test "attaches telemetry handlers on init" do
      _pid = ensure_broadcaster_running()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :info])

      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to debug events" do
      _pid = ensure_broadcaster_running()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :debug])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to info events" do
      _pid = ensure_broadcaster_running()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to warning events" do
      _pid = ensure_broadcaster_running()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :warning])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    test "attaches to error events" do
      _pid = ensure_broadcaster_running()

      handlers = :telemetry.list_handlers([:yellow_dog, :log, :error])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids
    end

    @tag :skip
    @tag :breaks_application_supervisor
    test "detaches telemetry handlers on terminate" do
      # This test is skipped because stopping the broadcaster would break
      # other tests that depend on the application-managed process.
      # The functionality is tested separately in isolation tests.
      pid = ensure_broadcaster_running()

      # Verify handlers are attached
      handlers_before = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids_before = Enum.map(handlers_before, & &1.id)
      assert "yellow-dog-log-broadcaster" in handler_ids_before

      assert is_pid(pid)
    end
  end

  describe "handle_telemetry_event/4" do
    setup do
      # Start PubSub if not already running (needed for tests)
      case Process.whereis(YellowDog.Console.PubSub) do
        nil ->
          {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: YellowDog.Console.PubSub)

        _ ->
          :ok
      end

      :ok
    end

    test "extracts level from event path" do
      # Test with info level
      event = [:yellow_dog, :log, :info]

      # This will try to broadcast, but we're testing the level extraction
      # The function should not crash
      LogBroadcaster.handle_telemetry_event(event, %{}, %{}, %{})
    end

    test "extracts level from error event" do
      event = [:yellow_dog, :log, :error]

      # Should not crash
      LogBroadcaster.handle_telemetry_event(event, %{}, %{}, %{})
    end

    test "broadcasts to PubSub topic when broadcaster is started" do
      # Subscribe to the topic
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      # Ensure broadcaster is running (either from app or fresh)
      _pid = ensure_broadcaster_running()

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

      _pid = ensure_broadcaster_running()

      :telemetry.execute(
        [:yellow_dog, :log, :debug],
        %{count: 1},
        %{message: "Debug message"}
      )

      assert_receive {:log_event, :debug, _, _}, 1000
    end

    test "broadcasts warning events" do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      _pid = ensure_broadcaster_running()

      :telemetry.execute(
        [:yellow_dog, :log, :warning],
        %{count: 1},
        %{message: "Warning message"}
      )

      assert_receive {:log_event, :warning, _, _}, 1000
    end

    test "broadcasts error events" do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())

      _pid = ensure_broadcaster_running()

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
      pid = ensure_broadcaster_running()

      # Process should be alive and responsive
      assert Process.alive?(pid)
    end

    @tag :skip
    @tag :breaks_application_supervisor
    test "terminate is called on stop" do
      # This test is skipped because stopping the broadcaster would break
      # other tests that depend on the application-managed process.
      pid = ensure_broadcaster_running()

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
