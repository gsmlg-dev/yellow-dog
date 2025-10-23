defmodule Abyss.LoggerTest do
  use ExUnit.Case, async: false

  alias Abyss.Logger

  describe "attach_logger/1" do
    test "attaches error level logger" do
      Logger.attach_logger(:error)

      # Verify the logger is attached by emitting a test event
      :telemetry.execute([:abyss, :acceptor, :spawn_error], %{error: :test_error}, %{
        socket: :test
      })

      Logger.detach_logger(:error)
    end

    test "attaches info level logger" do
      Logger.attach_logger(:info)

      # Verify the logger is attached by emitting a test event
      :telemetry.execute([:abyss, :listener, :start], %{timestamp: :test}, %{listener_id: 1})

      Logger.detach_logger(:info)
    end

    test "attaches debug level logger" do
      Logger.attach_logger(:debug)

      # Verify the logger is attached by emitting a test event
      :telemetry.execute([:abyss, :acceptor, :start], %{timestamp: :test}, %{listener_id: 1})

      Logger.detach_logger(:debug)
    end

    test "attaches trace level logger" do
      Logger.attach_logger(:trace)

      # Verify the logger is attached by emitting a test event
      :telemetry.execute([:abyss, :connection, :ready], %{timestamp: :test}, %{connection_id: 1})

      Logger.detach_logger(:trace)
    end

    test "returns error when attaching duplicate logger" do
      Logger.attach_logger(:error)
      result = Logger.attach_logger(:error)
      assert result == {:error, :already_exists}

      Logger.detach_logger(:error)
    end
  end

  describe "detach_logger/1" do
    test "detaches error level logger" do
      Logger.attach_logger(:error)
      assert :ok = Logger.detach_logger(:error)

      # Should return error when detaching already detached logger
      assert {:error, :not_found} = Logger.detach_logger(:error)
    end

    test "detaches info level logger" do
      Logger.attach_logger(:info)
      assert :ok = Logger.detach_logger(:info)
    end

    test "detaches debug level logger" do
      Logger.attach_logger(:debug)
      assert :ok = Logger.detach_logger(:debug)
    end

    test "detaches trace level logger" do
      Logger.attach_logger(:trace)
      assert :ok = Logger.detach_logger(:trace)
    end
  end

  describe "log functions" do
    test "log_error/4 logs error events" do
      event = [:abyss, :acceptor, :spawn_error]
      measurements = %{error: :test_error}
      metadata = %{socket: :test_socket}

      # This should not crash
      Logger.log_error(event, measurements, metadata, nil)
    end

    test "log_info/4 logs info events" do
      event = [:abyss, :listener, :start]
      measurements = %{timestamp: :test}
      metadata = %{listener_id: 1}

      # This should not crash
      Logger.log_info(event, measurements, metadata, nil)
    end

    test "log_debug/4 logs debug events" do
      event = [:abyss, :acceptor, :start]
      measurements = %{timestamp: :test}
      metadata = %{listener_id: 1}

      # This should not crash
      Logger.log_debug(event, measurements, metadata, nil)
    end

    test "log_trace/4 logs trace events" do
      event = [:abyss, :connection, :ready]
      measurements = %{timestamp: :test}
      metadata = %{connection_id: 1}

      # This should not crash
      Logger.log_trace(event, measurements, metadata, nil)
    end
  end

  describe "hierarchical logger attachment" do
    test "attach_logger(:info) also attaches error level" do
      Logger.attach_logger(:info)

      # Both error and info events should be logged
      :telemetry.execute([:abyss, :acceptor, :spawn_error], %{error: :test}, %{socket: :test})
      :telemetry.execute([:abyss, :listener, :start], %{timestamp: :test}, %{listener_id: 1})

      Logger.detach_logger(:info)
    end

    test "attach_logger(:debug) also attaches info and error levels" do
      Logger.attach_logger(:debug)

      # All debug, info, and error events should be logged
      :telemetry.execute([:abyss, :acceptor, :spawn_error], %{error: :test}, %{socket: :test})
      :telemetry.execute([:abyss, :listener, :start], %{timestamp: :test}, %{listener_id: 1})
      :telemetry.execute([:abyss, :acceptor, :start], %{timestamp: :test}, %{listener_id: 1})

      Logger.detach_logger(:debug)
    end

    test "attach_logger(:trace) attaches all levels" do
      Logger.attach_logger(:trace)

      # All events should be logged
      :telemetry.execute([:abyss, :acceptor, :spawn_error], %{error: :test}, %{socket: :test})
      :telemetry.execute([:abyss, :listener, :start], %{timestamp: :test}, %{listener_id: 1})
      :telemetry.execute([:abyss, :acceptor, :start], %{timestamp: :test}, %{listener_id: 1})
      :telemetry.execute([:abyss, :connection, :ready], %{timestamp: :test}, %{connection_id: 1})

      Logger.detach_logger(:trace)
    end
  end

  describe "hierarchical logger detachment" do
    test "detach_logger(:error) also detaches info, debug, and trace" do
      Logger.attach_logger(:trace)
      Logger.detach_logger(:error)

      # All should be detached
      assert {:error, :not_found} = Logger.detach_logger(:error)
      assert {:error, :not_found} = Logger.detach_logger(:info)
      assert {:error, :not_found} = Logger.detach_logger(:debug)
      assert {:error, :not_found} = Logger.detach_logger(:trace)
    end

    test "detach_logger(:info) also detaches debug and trace" do
      Logger.attach_logger(:trace)
      Logger.detach_logger(:info)

      # info, debug, and trace should be detached, but error remains
      assert {:error, :not_found} = Logger.detach_logger(:info)
      assert {:error, :not_found} = Logger.detach_logger(:debug)
      assert {:error, :not_found} = Logger.detach_logger(:trace)

      # Clean up
      Logger.detach_logger(:error)
    end

    test "detach_logger(:debug) also detaches trace" do
      Logger.attach_logger(:trace)
      Logger.detach_logger(:debug)

      # debug and trace should be detached, but info and error remain
      assert {:error, :not_found} = Logger.detach_logger(:debug)
      assert {:error, :not_found} = Logger.detach_logger(:trace)

      # Clean up
      Logger.detach_logger(:info)
    end
  end
end
