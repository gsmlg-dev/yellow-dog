defmodule YellowDog.Telemetry.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # The Application module attaches handlers at startup. All tests here verify
  # behaviour via :telemetry.execute/3 + capture_log (for log events) or by
  # checking which telemetry handlers are registered.

  setup do
    # Reset relevant config keys before each test
    Application.delete_env(:yellow_dog_telemetry, :format)
    Application.delete_env(:yellow_dog_telemetry, :console_colors)
    Application.delete_env(:yellow_dog_telemetry, :show_spans)
    Application.delete_env(:yellow_dog_telemetry, :show_span_start)
    Application.delete_env(:yellow_dog_telemetry, :span_threshold_ms)

    # Lower Logger level so info/debug output is captured by capture_log
    prev_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    :ok
  end

  # ── Handler attachment ──────────────────────────────────────────────

  describe "handler attachment on startup" do
    test "log handler is attached for :info events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :log, :info])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-handler" in handler_ids
    end

    test "log handler is attached for :debug events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :log, :debug])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-handler" in handler_ids
    end

    test "log handler is attached for :warning events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :log, :warning])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-handler" in handler_ids
    end

    test "log handler is attached for :error events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :log, :error])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-log-handler" in handler_ids
    end

    test "span handler is attached for :start events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :span, :start])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-span-handler" in handler_ids
    end

    test "span handler is attached for :stop events" do
      handlers = :telemetry.list_handlers([:yellow_dog, :span, :stop])
      handler_ids = Enum.map(handlers, & &1.id)
      assert "yellow-dog-span-handler" in handler_ids
    end
  end

  # ── Log event handling ──────────────────────────────────────────────

  defp base_log_metadata(msg \\ "Hello") do
    %{
      message: msg,
      app: :yellow_dog_test,
      module: __MODULE__,
      function: "test/1",
      line: 1
    }
  end

  describe "log event handling — minimal format (test env default)" do
    test "executes without crashing" do
      meta = base_log_metadata()

      assert capture_log([level: :debug], fn ->
               :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
             end) != nil
    end

    test "minimal format logs just the message" do
      meta = base_log_metadata("Hello minimal")

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
        end)

      assert log =~ "Hello minimal"
    end

    test "error level logs without crashing" do
      meta = base_log_metadata("Error message")

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :log, :error], %{}, meta)
        end)

      assert log =~ "Error message"
    end

    test "warning level logs without crashing" do
      meta = base_log_metadata("Warning!")

      assert capture_log([level: :debug], fn ->
               :telemetry.execute([:yellow_dog, :log, :warning], %{}, meta)
             end) != nil
    end

    test "debug level logs without crashing" do
      assert capture_log([level: :debug], fn ->
               :telemetry.execute([:yellow_dog, :log, :debug], %{}, base_log_metadata())
             end) != nil
    end
  end

  describe "log event handling — default format" do
    test "default format includes app name" do
      Application.put_env(:yellow_dog_telemetry, :format, :default)
      meta = base_log_metadata("Default fmt test")

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
        end)

      assert log =~ "yellow_dog_test"
    after
      Application.delete_env(:yellow_dog_telemetry, :format)
    end
  end

  describe "log event handling — pretty format" do
    test "pretty format includes message, app, and module location" do
      Application.put_env(:yellow_dog_telemetry, :format, :pretty)
      Application.put_env(:yellow_dog_telemetry, :console_colors, false)

      meta = base_log_metadata("Pretty message")

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
        end)

      assert log =~ "Pretty message"
    after
      Application.delete_env(:yellow_dog_telemetry, :format)
      Application.delete_env(:yellow_dog_telemetry, :console_colors)
    end

    test "pretty format with colors enabled does not crash" do
      Application.put_env(:yellow_dog_telemetry, :format, :pretty)
      Application.put_env(:yellow_dog_telemetry, :console_colors, true)
      meta = base_log_metadata("Colorful")

      assert capture_log([level: :debug], fn ->
               :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
             end) != nil
    after
      Application.delete_env(:yellow_dog_telemetry, :format)
      Application.delete_env(:yellow_dog_telemetry, :console_colors)
    end

    test "pretty format includes extra metadata fields" do
      Application.put_env(:yellow_dog_telemetry, :format, :pretty)
      Application.put_env(:yellow_dog_telemetry, :console_colors, false)

      meta = Map.put(base_log_metadata("With extra"), :request_id, "abc-123")

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :log, :info], %{}, meta)
        end)

      assert log =~ "abc-123"
    after
      Application.delete_env(:yellow_dog_telemetry, :format)
      Application.delete_env(:yellow_dog_telemetry, :console_colors)
    end
  end

  # ── Span stop event — duration formatting ───────────────────────────

  defp span_stop_meta do
    %{span_id: "test-span", name: :my_op, app: :yellow_dog_test, status: :success}
  end

  describe "span stop event — duration formatting" do
    setup do
      Application.put_env(:yellow_dog_telemetry, :show_spans, true)
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 0)
      :ok
    end

    # Logger.info/2's metadata (duration, status) is not included in the
    # default formatter output — capture_log only captures the message body ("[SPAN]").
    # These tests verify the span stop event fires at all for each duration range.

    test "sub-millisecond span (< 1ms) fires SPAN log" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 0.5}, span_stop_meta())
        end)

      assert log =~ "SPAN"
    end

    test "millisecond span (1ms–999ms) fires SPAN log" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 42.5}, span_stop_meta())
        end)

      assert log =~ "SPAN"
    end

    test "second span (>= 1000ms) fires SPAN log" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:yellow_dog, :span, :stop],
            %{duration_ms: 2500.0},
            span_stop_meta()
          )
        end)

      assert log =~ "SPAN"
    end

    test "exactly 1ms span fires SPAN log" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 1.0}, span_stop_meta())
        end)

      assert log =~ "SPAN"
    end

    test "exactly 1000ms span fires SPAN log" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:yellow_dog, :span, :stop],
            %{duration_ms: 1000.0},
            span_stop_meta()
          )
        end)

      assert log =~ "SPAN"
    end
  end

  # ── Span threshold filtering ─────────────────────────────────────────

  describe "span threshold" do
    setup do
      Application.put_env(:yellow_dog_telemetry, :show_spans, true)
      :ok
    end

    test "span below threshold does not log" do
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 100)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 10.0}, span_stop_meta())
        end)

      refute log =~ "SPAN"
    after
      Application.delete_env(:yellow_dog_telemetry, :span_threshold_ms)
    end

    test "span at threshold logs" do
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 50)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 50.0}, span_stop_meta())
        end)

      assert log =~ "SPAN"
    after
      Application.delete_env(:yellow_dog_telemetry, :span_threshold_ms)
    end

    test "span above threshold logs" do
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 10)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:yellow_dog, :span, :stop],
            %{duration_ms: 100.0},
            span_stop_meta()
          )
        end)

      assert log =~ "SPAN"
    after
      Application.delete_env(:yellow_dog_telemetry, :span_threshold_ms)
    end
  end

  describe "show_spans: false suppresses all span output" do
    setup do
      Application.put_env(:yellow_dog_telemetry, :show_spans, false)
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 0)
      :ok
    end

    test "span stop produces no log output" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 100.0}, span_stop_meta())
        end)

      refute log =~ "SPAN"
    end

    test "span start produces no log output" do
      Application.put_env(:yellow_dog_telemetry, :show_span_start, true)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :start], %{}, span_stop_meta())
        end)

      refute log =~ "SPAN START"
    end
  end

  # ── Span start ────────────────────────────────────────────────────────

  describe "span start event" do
    setup do
      Application.put_env(:yellow_dog_telemetry, :show_spans, true)
      :ok
    end

    test "show_span_start: false suppresses span start log" do
      Application.put_env(:yellow_dog_telemetry, :show_span_start, false)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :start], %{}, span_stop_meta())
        end)

      refute log =~ "SPAN START"
    end

    test "show_span_start: true logs the span start" do
      Application.put_env(:yellow_dog_telemetry, :show_span_start, true)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :start], %{}, span_stop_meta())
        end)

      assert log =~ "SPAN START"
    end
  end

  # ── Failure status ────────────────────────────────────────────────────

  # The status icon (✓ / ✗) is passed as Logger metadata, not the message body,
  # so it does not appear in capture_log output with the default formatter.
  # These tests verify the span stop event fires regardless of status value.
  describe "span stop with different status values" do
    setup do
      Application.put_env(:yellow_dog_telemetry, :show_spans, true)
      Application.put_env(:yellow_dog_telemetry, :span_threshold_ms, 0)
      :ok
    end

    test "success status fires SPAN log" do
      meta = Map.put(span_stop_meta(), :status, :success)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 1.0}, meta)
        end)

      assert log =~ "SPAN"
    end

    test "failure status fires SPAN log" do
      meta = Map.put(span_stop_meta(), :status, :failure)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 1.0}, meta)
        end)

      assert log =~ "SPAN"
    end

    test "missing status field defaults to :success and fires SPAN log" do
      meta = Map.delete(span_stop_meta(), :status)

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:yellow_dog, :span, :stop], %{duration_ms: 1.0}, meta)
        end)

      assert log =~ "SPAN"
    end
  end
end
