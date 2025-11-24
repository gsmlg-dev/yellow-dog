defmodule Abyss.TelemetryIntegrationTest do
  use ExUnit.Case, async: false

  alias Abyss.Telemetry

  describe "telemetry integration with server lifecycle" do
    test "metrics work correctly with server start and stop" do
      # Initialize metrics
      Telemetry.reset_metrics()

      # Simulate server lifecycle
      # Server starts - connections should be 0
      initial_metrics = Telemetry.get_metrics()
      assert initial_metrics.connections_active == 0
      assert initial_metrics.connections_total == 0

      # Simulate accepting connections
      for _i <- 1..5 do
        Telemetry.track_connection_accepted()
      end

      # Some connections process responses
      for i <- 1..3 do
        Telemetry.track_response_sent(i * 20)
        Telemetry.track_connection_closed()
      end

      final_metrics = Telemetry.get_metrics()
      assert final_metrics.connections_total == 5
      assert final_metrics.accepts_total == 5
      assert final_metrics.responses_total == 3
      assert final_metrics.connections_active == 2
    end

    test "response time tracking emits telemetry events" do
      # Set up telemetry event capture
      test_pid = self()
      handler_id = :integration_test_handler

      :telemetry.attach_many(
        handler_id,
        [[:abyss, :metrics, :response_time]],
        fn [:abyss, :metrics, :response_time], measurements, _metadata, _config ->
          send(test_pid, {:response_time, measurements.response_time})
        end,
        %{}
      )

      # Track various response times
      response_times = [10, 25, 50, 100, 200]

      for time <- response_times do
        Telemetry.track_response_sent(time)
      end

      # Verify all events were received
      received_times =
        for _ <- response_times do
          assert_receive {:response_time, received_time}, 1000
          received_time
        end

      assert Enum.sort(received_times) == Enum.sort(response_times)

      # Clean up
      :telemetry.detach(handler_id)
    end

    test "metrics calculation under load" do
      Telemetry.reset_metrics()

      # Simulate high load
      num_operations = 1000

      start_time = System.monotonic_time(:millisecond)

      # Perform mixed operations
      for i <- 1..num_operations do
        cond do
          rem(i, 3) == 0 ->
            Telemetry.track_connection_accepted()

          rem(i, 5) == 0 ->
            Telemetry.track_response_sent(:rand.uniform(100))

          rem(i, 7) == 0 ->
            Telemetry.track_connection_closed()

          true ->
            :ok
        end
      end

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Wait for rate window to stabilize (rolling window calculation)
      Process.sleep(1100)

      metrics = Telemetry.get_metrics()

      # Verify reasonable values
      assert metrics.connections_total > 0
      assert metrics.responses_total > 0
      assert metrics.accepts_total > 0
      assert metrics.connections_active >= 0

      # With rolling window, rates should be 0 after window expires with no new events
      assert metrics.accepts_per_second >= 0
      assert metrics.responses_per_second >= 0

      # Performance check - operations should complete quickly
      # Should complete within 1 second
      assert duration_ms < 1000
    end

    test "consistency of metrics data" do
      Telemetry.reset_metrics()

      # Perform operations in a known pattern
      operations = [
        # Accept 10 connections
        {:accept, 10},
        # Send 5 responses
        {:response, 5},
        # Close 3 connections
        {:close, 3},
        # Accept 5 more connections
        {:accept, 5},
        # Send 8 responses
        {:response, 8},
        # Close 2 connections
        {:close, 2}
      ]

      for {type, count} <- operations do
        for _i <- 1..count do
          case type do
            :accept ->
              Telemetry.track_connection_accepted()

            :response ->
              Telemetry.track_response_sent(:rand.uniform(50) + 10)

            :close ->
              Telemetry.track_connection_closed()
          end
        end
      end

      metrics = Telemetry.get_metrics()

      # Verify mathematical consistency
      # Total accepts should equal total connections
      assert metrics.accepts_total == metrics.connections_total

      # Active connections should be >= 0
      assert metrics.connections_active >= 0

      # All counts should be reasonable
      # 10 + 5
      assert metrics.connections_total == 15
      # 5 + 8
      assert metrics.responses_total == 13
      # 15 - 3 - 2
      assert metrics.connections_active == 10

      # Rates should be non-negative
      assert metrics.accepts_per_second >= 0
      assert metrics.responses_per_second >= 0
    end

    test "metrics reset functionality" do
      # Build up some state
      for _i <- 1..50 do
        Telemetry.track_connection_accepted()
        Telemetry.track_response_sent(25)
      end

      # Close some connections
      for _i <- 1..20 do
        Telemetry.track_connection_closed()
      end

      pre_reset_metrics = Telemetry.get_metrics()
      assert pre_reset_metrics.connections_total == 50
      assert pre_reset_metrics.responses_total == 50
      assert pre_reset_metrics.connections_active == 30

      # Reset and verify
      Telemetry.reset_metrics()

      post_reset_metrics = Telemetry.get_metrics()
      assert post_reset_metrics.connections_active == 0
      assert post_reset_metrics.connections_total == 0
      assert post_reset_metrics.accepts_total == 0
      assert post_reset_metrics.responses_total == 0
      assert post_reset_metrics.accepts_per_second == 0
      assert post_reset_metrics.responses_per_second == 0
    end
  end
end
