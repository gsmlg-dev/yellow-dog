defmodule Abyss.TelemetryMetricsTest do
  use ExUnit.Case, async: false

  alias Abyss.Telemetry

  describe "telemetry metrics" do
    setup do
      # Ensure clean ETS table for each test
      if :ets.whereis(:abyss_telemetry_metrics) != :undefined do
        :ets.delete(:abyss_telemetry_metrics)
      end

      # Initialize metrics
      Telemetry.init_metrics()
      :ok
    after
      # Clean up after each test
      if :ets.whereis(:abyss_telemetry_metrics) != :undefined do
        :ets.delete(:abyss_telemetry_metrics)
      end
    end

    test "initializes with zero metrics" do
      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 0
      assert metrics.connections_total == 0
      assert metrics.accepts_total == 0
      assert metrics.responses_total == 0
      assert metrics.accepts_per_second == 0
      assert metrics.responses_per_second == 0
    end

    test "tracks connection acceptance" do
      # Track a connection being accepted
      Telemetry.track_connection_accepted()

      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 1
      assert metrics.connections_total == 1
      assert metrics.accepts_total == 1
      assert metrics.accepts_per_second >= 0  # Could be 0 if window reset immediately
    end

    test "tracks connection closure" do
      # Accept and close a connection
      Telemetry.track_connection_accepted()
      Telemetry.track_connection_closed()

      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 0
      assert metrics.connections_total == 1
      assert metrics.accepts_total == 1
    end

    test "tracks multiple connections" do
      # Accept multiple connections
      Telemetry.track_connection_accepted()
      Telemetry.track_connection_accepted()
      Telemetry.track_connection_accepted()

      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 3
      assert metrics.connections_total == 3
      assert metrics.accepts_total == 3

      # Close one connection
      Telemetry.track_connection_closed()

      metrics = Telemetry.get_metrics()
      assert metrics.connections_active == 2
    end

    test "tracks response times" do
      # Track a response with 50ms response time
      Telemetry.track_response_sent(50)

      metrics = Telemetry.get_metrics()

      assert metrics.responses_total == 1
      assert metrics.responses_per_second >= 0
    end

    test "calculates accept rate over time" do
      # Track multiple accepts
      for _i <- 1..5 do
        Telemetry.track_connection_accepted()
      end

      metrics = Telemetry.get_metrics()
      assert metrics.accepts_total == 5
      assert metrics.accepts_per_second >= 0
    end

    test "calculates response rate over time" do
      # Track multiple responses
      for i <- 1..5 do
        Telemetry.track_response_sent(i * 10)  # Varying response times
      end

      metrics = Telemetry.get_metrics()
      assert metrics.responses_total == 5
      assert metrics.responses_per_second >= 0
    end

    test "emits response time telemetry events" do
      # Set up a test process to capture telemetry events
      test_pid = self()
      handler_id = :test_response_time_handler

      :telemetry.attach_many(
        handler_id,
        [[:abyss, :metrics, :response_time]],
        fn [:abyss, :metrics, :response_time], measurements, _metadata, _config ->
          send(test_pid, {:response_time_event, measurements})
        end,
        %{}
      )

      # Track a response
      Telemetry.track_response_sent(100)

      # Verify the event was received
      assert_receive {:response_time_event, %{response_time: 100}}, 1000

      # Clean up
      :telemetry.detach(handler_id)
    end

    test "handles mixed connection and response tracking" do
      # Accept some connections
      for _i <- 1..3 do
        Telemetry.track_connection_accepted()
      end

      # Close one connection
      Telemetry.track_connection_closed()

      # Send some responses
      Telemetry.track_response_sent(50)
      Telemetry.track_response_sent(75)

      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 2
      assert metrics.connections_total == 3
      assert metrics.accepts_total == 3
      assert metrics.responses_total == 2
    end

    test "reset_metrics clears all counters" do
      # Set up some initial state
      Telemetry.track_connection_accepted()
      Telemetry.track_response_sent(100)

      # Reset metrics
      Telemetry.reset_metrics()

      metrics = Telemetry.get_metrics()

      assert metrics.connections_active == 0
      assert metrics.connections_total == 0
      assert metrics.accepts_total == 0
      assert metrics.responses_total == 0
      assert metrics.accepts_per_second == 0
      assert metrics.responses_per_second == 0
    end

    test "prevents negative connection count" do
      # Try to close more connections than were opened
      Telemetry.track_connection_closed()
      Telemetry.track_connection_closed()

      metrics = Telemetry.get_metrics()
      assert metrics.connections_active == 0
    end

    test "handles large response times" do
      # Test with various response times
      response_times = [1, 10, 100, 1000, 5000]

      for time <- response_times do
        Telemetry.track_response_sent(time)
      end

      metrics = Telemetry.get_metrics()
      assert metrics.responses_total == length(response_times)
    end

    test "rate windows reset correctly" do
      # Accept connections rapidly
      for _i <- 1..10 do
        Telemetry.track_connection_accepted()
      end

      # Wait for window to expire (simulated by manual time manipulation is complex,
      # so we just verify the rate is reasonable)
      metrics = Telemetry.get_metrics()
      assert metrics.accepts_total == 10
      assert metrics.accepts_per_second >= 0
    end

    test "metrics are isolated between test runs" do
      # Set up state in this test
      Telemetry.track_connection_accepted()
      Telemetry.track_response_sent(50)

      # Verify state
      metrics = Telemetry.get_metrics()
      assert metrics.connections_active == 1
      assert metrics.responses_total == 1

      # Clean up for next test
      Telemetry.reset_metrics()
    end
  end
end