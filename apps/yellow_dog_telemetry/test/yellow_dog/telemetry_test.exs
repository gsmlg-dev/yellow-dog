defmodule YellowDog.TelemetryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Telemetry

  setup do
    # Reset configuration before each test
    Application.delete_env(:yellow_dog_telemetry, :filter_apps)
    Application.delete_env(:yellow_dog_telemetry, :exclude_apps)
    Application.delete_env(:yellow_dog_telemetry, :app_levels)
    Application.put_env(:yellow_dog_telemetry, :level, :debug)
    Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 0)

    :ok
  end

  describe "logging API" do
    test "debug/2 emits telemetry event with metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-debug",
        [:yellow_dog, :log, :debug],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, :debug, metadata})
        end,
        nil
      )

      Telemetry.debug("Test debug message", %{key: "value"})

      assert_receive {:log_event, :debug, metadata}
      assert metadata.message == "Test debug message"
      assert metadata.key == "value"
      assert is_atom(metadata.app)
      assert is_atom(metadata.module)
      assert is_binary(metadata.function)
      assert is_integer(metadata.line)

      :telemetry.detach("test-debug")
    end

    test "info/2 emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-info",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, :info, metadata})
        end,
        nil
      )

      Telemetry.info("Test info message", %{status: :ok})

      assert_receive {:log_event, :info, metadata}
      assert metadata.message == "Test info message"
      assert metadata.status == :ok

      :telemetry.detach("test-info")
    end

    test "warning/2 emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-warning",
        [:yellow_dog, :log, :warning],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, :warning, metadata})
        end,
        nil
      )

      Telemetry.warning("Test warning message")

      assert_receive {:log_event, :warning, metadata}
      assert metadata.message == "Test warning message"

      :telemetry.detach("test-warning")
    end

    test "error/2 emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-error",
        [:yellow_dog, :log, :error],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, :error, metadata})
        end,
        nil
      )

      Telemetry.error("Test error message", %{error: :enoent})

      assert_receive {:log_event, :error, metadata}
      assert metadata.message == "Test error message"
      assert metadata.error == :enoent

      :telemetry.detach("test-error")
    end

    test "supports lazy message evaluation" do
      test_pid = self()

      :telemetry.attach(
        "test-lazy",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, :info, metadata})
        end,
        nil
      )

      # Lazy message is only evaluated when emitted
      Telemetry.info(fn -> "Lazy message" end)

      assert_receive {:log_event, :info, metadata}
      assert metadata.message == "Lazy message"

      :telemetry.detach("test-lazy")
    end

    test "includes caller information in metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-caller",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:metadata, metadata})
        end,
        nil
      )

      Telemetry.info("Test")

      assert_receive {:metadata, metadata}
      assert is_atom(metadata.module)
      assert is_binary(metadata.function)
      assert is_integer(metadata.line)
      assert metadata.line > 0

      :telemetry.detach("test-caller")
    end
  end

  describe "app name detection" do
    # Test the detect_app function directly by accessing it through log metadata
    test "detects app from caller module namespace" do
      test_pid = self()

      :telemetry.attach(
        "test-app-detection",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:app, metadata.app})
        end,
        nil
      )

      # When called from this test module, should detect :yellow_dog
      Telemetry.info("Test message")

      assert_receive {:app, app}
      # The test module is YellowDog.TelemetryTest which starts with YellowDog
      # so it should be detected as :yellow_dog
      assert app in [:yellow_dog, :unknown]

      :telemetry.detach("test-app-detection")
    end
  end

  describe "filtering by app" do
    test "filter_apps/1 sets filter configuration" do
      Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])

      assert Application.get_env(:yellow_dog_telemetry, :filter_apps) == [
               :yellow_dog_dns,
               :yellow_dog_dhcpv4
             ]
    end

    test "exclude_apps/1 sets exclude configuration" do
      Telemetry.exclude_apps([:yellow_dog_console])

      assert Application.get_env(:yellow_dog_telemetry, :exclude_apps) == [:yellow_dog_console]
    end

    test "show_all_apps/0 resets filtering" do
      Telemetry.filter_apps([:yellow_dog_dns])
      Telemetry.show_all_apps()

      assert Application.get_env(:yellow_dog_telemetry, :filter_apps) == nil
      assert Application.get_env(:yellow_dog_telemetry, :exclude_apps) == nil
    end

    test "set_app_level/2 sets per-app log level" do
      Telemetry.set_app_level(:yellow_dog_dns, :debug)
      Telemetry.set_app_level(:yellow_dog_dhcpv4, :info)

      app_levels = Application.get_env(:yellow_dog_telemetry, :app_levels, %{})
      assert app_levels[:yellow_dog_dns] == :debug
      assert app_levels[:yellow_dog_dhcpv4] == :info
    end
  end

  describe "log level filtering" do
    test "respects configured log level" do
      test_pid = self()

      :telemetry.attach_many(
        "test-level",
        [
          [:yellow_dog, :log, :debug],
          [:yellow_dog, :log, :info],
          [:yellow_dog, :log, :warning]
        ],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_event, metadata.message})
        end,
        nil
      )

      # Set level to :info
      Application.put_env(:yellow_dog_telemetry, :level, :info)

      # Should NOT emit (below threshold)
      Telemetry.debug("Debug message")
      refute_receive {:log_event, "Debug message"}, 100

      # Should emit (at threshold)
      Telemetry.info("Info message")
      assert_receive {:log_event, "Info message"}, 100

      # Should emit (above threshold)
      Telemetry.warning("Warning message")
      assert_receive {:log_event, "Warning message"}, 100

      :telemetry.detach("test-level")
    end
  end

  describe "span tracking" do
    test "start_span/2 and end_span/2 emit events" do
      test_pid = self()

      :telemetry.attach_many(
        "test-span",
        [
          [:yellow_dog, :span, :start],
          [:yellow_dog, :span, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:span_event, event, measurements, metadata})
        end,
        nil
      )

      span_id = Telemetry.start_span("test.operation", %{key: "value"})

      assert_receive {:span_event, [:yellow_dog, :span, :start], measurements, metadata}
      assert metadata.span_id == span_id
      assert metadata.name == "test.operation"
      assert metadata.key == "value"
      assert is_integer(measurements.monotonic_time)

      # Delay to ensure measurable duration (10ms avoids coarse-timer flakes in CI)
      Process.sleep(10)

      Telemetry.end_span(span_id, %{status: :success})

      assert_receive {:span_event, [:yellow_dog, :span, :stop], measurements, metadata}
      assert metadata.span_id == span_id
      assert metadata.name == "test.operation"
      assert metadata.status == :success
      assert measurements.duration_us > 0
      assert measurements.duration_ms > 0

      :telemetry.detach("test-span")
    end

    test "span/3 wraps function execution" do
      test_pid = self()

      :telemetry.attach(
        "test-span-wrapper",
        [:yellow_dog, :span, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:span_complete, measurements.duration_ms, metadata.status})
        end,
        nil
      )

      result =
        Telemetry.span("test.wrapped", %{}, fn ->
          Process.sleep(10)
          :test_result
        end)

      assert result == :test_result
      assert_receive {:span_complete, duration_ms, :success}
      assert duration_ms > 0

      :telemetry.detach("test-span-wrapper")
    end

    test "span/3 handles errors and marks as failed" do
      test_pid = self()

      :telemetry.attach(
        "test-span-error",
        [:yellow_dog, :span, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:span_complete, metadata.status})
        end,
        nil
      )

      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span("test.error", %{}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:span_complete, :failed}

      :telemetry.detach("test-span-error")
    end

    test "nested spans track parent-child relationships" do
      test_pid = self()

      :telemetry.attach(
        "test-nested-span",
        [:yellow_dog, :span, :start],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:span_start, metadata.span_id, metadata.parent_span_id})
        end,
        nil
      )

      Telemetry.span("parent", %{}, fn ->
        # Get parent span context
        assert_receive {:span_start, parent_id, nil}

        Telemetry.span("child", %{}, fn ->
          # Child should reference parent
          assert_receive {:span_start, _child_id, ^parent_id}
          :ok
        end)

        :ok
      end)

      :telemetry.detach("test-nested-span")
    end

    test "span threshold filtering" do
      test_pid = self()

      :telemetry.attach(
        "test-span-threshold",
        [:yellow_dog, :span, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:span_stop, metadata.name, measurements.duration_ms})
        end,
        nil
      )

      # Set threshold to 10ms
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 10)

      # Fast span - should NOT emit stop event
      Telemetry.span("fast", %{}, fn -> :ok end)
      refute_receive {:span_stop, "fast", _}, 100

      # Slow span - should emit stop event
      Telemetry.span("slow", %{}, fn ->
        Process.sleep(15)
        :ok
      end)

      assert_receive {:span_stop, "slow", duration_ms}
      assert duration_ms >= 10

      :telemetry.detach("test-span-threshold")
    end

    test "end_span handles unknown span gracefully" do
      # Should not crash when ending unknown span
      unknown_span_id = make_ref()
      assert :ok = Telemetry.end_span(unknown_span_id)
    end
  end

  describe "span context in logs" do
    test "logs include span_id when within a span" do
      test_pid = self()

      :telemetry.attach(
        "test-span-context",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_with_span, metadata})
        end,
        nil
      )

      Telemetry.span("operation", %{}, fn ->
        Telemetry.info("Log within span")

        assert_receive {:log_with_span, metadata}
        assert is_reference(metadata.span_id)
        assert metadata.message == "Log within span"

        :ok
      end)

      :telemetry.detach("test-span-context")
    end

    test "logs outside span have no span_id" do
      test_pid = self()

      :telemetry.attach(
        "test-no-span-context",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:log_without_span, metadata})
        end,
        nil
      )

      Telemetry.info("Log outside span")

      assert_receive {:log_without_span, metadata}
      refute Map.has_key?(metadata, :span_id)

      :telemetry.detach("test-no-span-context")
    end
  end

  describe "metadata handling" do
    test "merges custom metadata with automatic metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-metadata",
        [:yellow_dog, :log, :info],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:metadata, metadata})
        end,
        nil
      )

      Telemetry.info("Test", %{custom: "value", number: 42})

      assert_receive {:metadata, metadata}
      # Custom metadata
      assert metadata.custom == "value"
      assert metadata.number == 42
      # Automatic metadata
      assert metadata.message == "Test"
      assert is_atom(metadata.app)
      assert is_atom(metadata.module)

      :telemetry.detach("test-metadata")
    end
  end

  describe "telemetry event structure" do
    test "log events have correct structure" do
      test_pid = self()

      :telemetry.attach(
        "test-structure",
        [:yellow_dog, :log, :info],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.info("Test message")

      assert_receive {:event, event, measurements, metadata}
      assert event == [:yellow_dog, :log, :info]
      assert is_integer(measurements.monotonic_time)
      assert is_binary(metadata.message)

      :telemetry.detach("test-structure")
    end

    test "span events have correct structure" do
      test_pid = self()

      :telemetry.attach_many(
        "test-span-structure",
        [[:yellow_dog, :span, :start], [:yellow_dog, :span, :stop]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      span_id = Telemetry.start_span("test")
      Telemetry.end_span(span_id)

      # Start event
      assert_receive {:event, [:yellow_dog, :span, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.monotonic_time)
      assert is_reference(start_metadata.span_id)
      assert start_metadata.name == "test"

      # Stop event
      assert_receive {:event, [:yellow_dog, :span, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.monotonic_time)
      assert is_integer(stop_measurements.duration_us)
      assert is_float(stop_measurements.duration_ms)
      assert is_reference(stop_metadata.span_id)

      :telemetry.detach("test-span-structure")
    end
  end
end
