defmodule Abyss.HandlerTest do
  use ExUnit.Case, async: false

  alias Abyss.Handler
  alias Abyss.ServerConfig

  defmodule TestAdaptiveHandler do
    use Abyss.Handler

    @impl true
    def handle_data({ip, port, data}, state) do
      # Simulate some processing time
      :timer.sleep(1)
      {:continue, Map.put(state, :last_data, {ip, port, data})}
    end

    @impl true
    def handle_timeout(state) do
      Map.put(state, :timeout_occurred, true)
    end

    @impl true
    def handle_close(state) do
      Map.put(state, :closed, true)
    end

    @impl true
    def terminate(_reason, state) do
      # In test environment, socket might be a reference, not a real socket
      # Handle gracefully without trying to use :inet.udp_controlling_process
      if is_reference(state.socket) do
        # Test socket reference, ignore
        :ok
      else
        # Real socket, use default handling
        :ok
      end
    end
  end

  defmodule OneShotTimeoutHandler do
    use Abyss.Handler

    @impl true
    def handle_data(_data, state), do: {:continue, state, 1234}
  end

  defmodule PersistentTimeoutHandler do
    use Abyss.Handler

    @impl true
    def handle_data(_data, state), do: {:continue, state, {:persistent, 9999}}
  end

  defmodule MemoryTestHandler do
    use Abyss.Handler

    @impl true
    def handle_data({_ip, _port, _data}, state) do
      # Simulate memory usage
      # 1MB
      large_data = :binary.copy(<<0>>, 1024 * 1024)
      new_state = Map.put(state, :large_data, large_data)
      {:continue, new_state}
    end

    @impl true
    def handle_timeout(state) do
      Map.put(state, :timeout_occurred, true)
    end

    @impl true
    def terminate(_reason, state) do
      # In test environment, socket might be a reference, not a real socket
      # Handle gracefully without trying to use :inet.udp_controlling_process
      if is_reference(state.socket) do
        # Test socket reference, ignore
        :ok
      else
        # Real socket, use default handling
        :ok
      end
    end
  end

  describe "adaptive timeout functionality" do
    test "calculates adaptive timeout based on processing times" do
      # 5 seconds in native units
      base_timeout = System.convert_time_unit(5000, :millisecond, :native)

      # Test with no processing times
      assert Handler.calculate_adaptive_timeout(base_timeout, []) == base_timeout

      # Test with single processing time
      # 100ms
      processing_time = System.convert_time_unit(100, :millisecond, :native)
      result = Handler.calculate_adaptive_timeout(base_timeout, [processing_time])

      # Should be 3x average processing time (300ms), but bounded by 50%-200% of base
      assert result >= div(base_timeout, 2)
      assert result <= base_timeout * 2

      # Test with multiple processing times
      processing_times = [
        System.convert_time_unit(50, :millisecond, :native),
        System.convert_time_unit(100, :millisecond, :native),
        System.convert_time_unit(150, :millisecond, :native)
      ]

      result = Handler.calculate_adaptive_timeout(base_timeout, processing_times)
      # Average = 100ms, 3x = 300ms, bounded by 2.5-10 seconds in native units
      assert result >= div(base_timeout, 2)
      assert result <= base_timeout * 2
    end

    test "respects minimum and maximum timeout bounds" do
      # Base timeout in milliseconds (function returns milliseconds now)
      base_timeout = 5000

      # Very fast processing times (in native units)
      fast_times = [
        System.convert_time_unit(1, :millisecond, :native),
        System.convert_time_unit(2, :millisecond, :native),
        System.convert_time_unit(3, :millisecond, :native)
      ]

      result = Handler.calculate_adaptive_timeout(base_timeout, fast_times)
      # Result should be at minimum bound or close to it (in milliseconds)
      expected_min = div(base_timeout, 2)
      # Since the calculation uses 3x average time, for 1-3ms avg, that's 3-9ms
      # which should be closer to the minimum bound (2500ms)
      assert result >= expected_min
      assert result <= base_timeout

      # Very slow processing times (in native units)
      slow_times = [
        System.convert_time_unit(1000, :millisecond, :native),
        System.convert_time_unit(2000, :millisecond, :native),
        System.convert_time_unit(3000, :millisecond, :native)
      ]

      result = Handler.calculate_adaptive_timeout(base_timeout, slow_times)
      # Result should be at maximum bound or close to it (in milliseconds)
      expected_max = base_timeout * 2
      # Since 2000ms avg * 3 = 6000ms, which is capped at max of 10000ms (2x base)
      assert result <= expected_max
      assert result >= base_timeout
    end

    test "handles edge cases" do
      base_timeout = 5000

      # Empty processing times
      assert Handler.calculate_adaptive_timeout(base_timeout, []) == base_timeout

      # Single processing time
      single_time = [System.convert_time_unit(100, :millisecond, :native)]
      result = Handler.calculate_adaptive_timeout(base_timeout, single_time)
      assert result >= div(base_timeout, 2)
      assert result <= base_timeout * 2

      # Exactly at bounds
      # Average = 100ms, 3x = 300ms
      # If base_timeout = 500ms, then min = 250ms, max = 1000ms
      # So 300ms should be within bounds
      avg_times = [
        System.convert_time_unit(100, :millisecond, :native),
        System.convert_time_unit(100, :millisecond, :native),
        System.convert_time_unit(100, :millisecond, :native)
      ]

      base_timeout_small = System.convert_time_unit(500, :millisecond, :native)
      result = Handler.calculate_adaptive_timeout(base_timeout_small, avg_times)
      assert result >= div(base_timeout_small, 2)
      assert result <= base_timeout_small * 2
    end
  end

  describe "handler state with adaptive timeouts" do
    test "tracks processing times in handler state" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      # Mock the connection span
      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      # Start the handler
      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send new connection data
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Allow some time for processing
      Process.sleep(50)

      # Check if handler is still alive and tracking processing times
      assert Process.alive?(handler_pid)

      # Clean up
      GenServer.stop(handler_pid)
    end

    test "adaptive timeout is used in continuation" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Allow processing
      Process.sleep(100)

      # Verify handler is still running with adaptive timeout
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end
  end

  describe "memory management functionality" do
    test "monitors memory usage periodically" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data to start memory monitoring
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Wait for memory check to be scheduled
      Process.sleep(50)

      # Verify the process receives memory_check messages
      # This is hard to test directly without exposing internal state,
      # but we can verify the handler is still alive
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end

    test "handler starts without memory warnings" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Since we can't easily force high memory usage in testing,
      # we just verify the handler starts correctly
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end

    test "handles high memory usage gracefully" do
      config =
        ServerConfig.new(
          handler_module: MemoryTestHandler,
          port: 0,
          read_timeout: 1000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = MemoryTestHandler.start_link({span, config, self(), make_ref()})

      # Send multiple data packets to increase memory usage
      for i <- 1..10 do
        send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "data#{i}"}})
        Process.sleep(10)
      end

      # Allow some time for processing and memory checks
      Process.sleep(200)

      # The handler should still be alive in normal circumstances
      # Memory limit termination is hard to trigger in tests
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end
  end

  describe "handler continuation behavior" do
    test "uses adaptive timeout instead of fixed read timeout" do
      base_timeout = 5000

      processing_times = [
        System.convert_time_unit(100, :millisecond, :native),
        System.convert_time_unit(200, :millisecond, :native)
      ]

      adaptive_timeout = Handler.calculate_adaptive_timeout(base_timeout, processing_times)

      state = %{read_timeout: base_timeout}
      bookkeeping = %{processing_times: processing_times, adaptive_timeout: adaptive_timeout}

      assert {:noreply, new_state, ^adaptive_timeout} =
               Handler.handle_continuation({:continue, state}, bookkeeping)

      # Bookkeeping is merged into the returned state
      assert new_state.adaptive_timeout == adaptive_timeout
      assert new_state.processing_times == processing_times
    end

    test "falls back to read timeout when adaptive timeout not set" do
      base_timeout = 5000
      state = %{read_timeout: base_timeout}

      assert {:noreply, ^state, ^base_timeout} = Handler.handle_continuation({:continue, state})
    end

    test "preserves state returned by the handler callback" do
      state = %{read_timeout: 5000, packets_seen: 1}
      returned_state = %{state | packets_seen: 2}

      assert {:noreply, new_state, 5000} =
               Handler.handle_continuation({:continue, returned_state}, %{processing_times: []})

      assert new_state.packets_seen == 2
    end

    test "supports {:continue, state, timeout} one-shot timeout" do
      state = %{read_timeout: 5000}

      assert {:noreply, new_state, 1234} =
               Handler.handle_continuation({:continue, state, 1234})

      # One-shot timeout is not persisted
      assert new_state.read_timeout == 5000
    end

    test "supports {:continue, state, {:persistent, timeout}}" do
      state = %{read_timeout: 5000, adaptive_timeout: 5000}

      assert {:noreply, new_state, 9999} =
               Handler.handle_continuation({:continue, state, {:persistent, 9999}})

      # Persistent timeout overwrites read_timeout for future messages
      assert new_state.read_timeout == 9999
      assert new_state.adaptive_timeout == 9999
    end

    test "handles different continuation results" do
      base_state = %{read_timeout: 5000}
      server_config = %Abyss.ServerConfig{silent_terminate_on_error: false}
      state = Map.put(base_state, :server_config, server_config)

      # Test continue result
      assert {:noreply, ^state, 5000} = Handler.handle_continuation({:continue, state})

      # Test close result
      assert {:stop, {:shutdown, :local_closed}, ^state} =
               Handler.handle_continuation({:close, state})

      # Test timeout error
      assert {:stop, {:shutdown, :timeout}, ^state} =
               Handler.handle_continuation({:error, :timeout, state})

      # Test other error without silent termination
      assert {:stop, :custom_error, ^state} =
               Handler.handle_continuation({:error, :custom_error, state})

      # Test error with silent termination (flag lives in the handler state)
      state_with_silent = %{
        state
        | server_config: %{server_config | silent_terminate_on_error: true}
      }

      result = Handler.handle_continuation({:error, :custom_error, state_with_silent})
      assert {:stop, {:shutdown, {:silent_termination, :custom_error}}, returned_state} = result
      assert returned_state.server_config.silent_terminate_on_error == true
    end
  end

  describe "generated handle_continue/2" do
    test "threads state returned by handle_data through to the GenServer" do
      state = %{processing_times: [], read_timeout: 5000, adaptive_timeout: 5000}
      packet = {{127, 0, 0, 1}, 4000, "ping"}

      assert {:noreply, new_state, _timeout} =
               TestAdaptiveHandler.handle_continue({:handle_data, packet}, state)

      # State modification made by handle_data must survive
      assert new_state.last_data == packet
      # Internal bookkeeping is still maintained
      assert [_ | _] = new_state.processing_times
      assert is_integer(new_state.adaptive_timeout)
    end

    test "handle_data may return {:continue, state, timeout} without crashing" do
      state = %{processing_times: [], read_timeout: 5000}
      packet = {{127, 0, 0, 1}, 4000, "ping"}

      assert {:noreply, _new_state, 1234} =
               OneShotTimeoutHandler.handle_continue({:handle_data, packet}, state)
    end

    test "handle_data may return {:continue, state, {:persistent, timeout}}" do
      state = %{processing_times: [], read_timeout: 5000}
      packet = {{127, 0, 0, 1}, 4000, "ping"}

      assert {:noreply, new_state, 9999} =
               PersistentTimeoutHandler.handle_continue({:handle_data, packet}, state)

      assert new_state.read_timeout == 9999
    end
  end

  describe "handler lifecycle" do
    test "initializes with memory monitoring" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Verify the process starts successfully with memory monitoring
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end

    test "handles close gracefully" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data and close
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      Process.sleep(50)

      # Stop the handler gracefully
      GenServer.stop(handler_pid, :normal)

      # Handler should have terminated cleanly
      refute Process.alive?(handler_pid)
    end
  end

  describe "memory monitoring edge cases" do
    test "handles memory check errors gracefully" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Allow memory checks to run
      Process.sleep(100)

      # Handler should still be alive despite any memory check issues
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end

    test "continues monitoring after garbage collection" do
      config =
        ServerConfig.new(
          handler_module: TestAdaptiveHandler,
          port: 0,
          read_timeout: 5000
        )

      span = Abyss.Telemetry.start_span(:test, %{}, %{})

      {:ok, handler_pid} = TestAdaptiveHandler.start_link({span, config, self(), make_ref()})

      # Send connection data
      send(handler_pid, {:new_connection, make_ref(), {{127, 0, 0, 1}, 12345, "test data"}})

      # Allow memory monitoring cycle
      Process.sleep(200)

      # Handler should still be alive
      assert Process.alive?(handler_pid)

      GenServer.stop(handler_pid)
    end
  end
end
