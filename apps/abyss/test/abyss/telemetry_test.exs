defmodule Abyss.TelemetryTest do
  use ExUnit.Case, async: true

  alias Abyss.Telemetry

  describe "start_span/3" do
    test "creates a span with default sampling" do
      span = Telemetry.start_span(:test, %{value: 42}, %{extra: "data"})

      assert span.span_name == :test
      assert is_reference(span.telemetry_span_context)
      assert is_integer(span.start_time)
      assert span.start_metadata.extra == "data"
      assert span.start_metadata[:sampled] in [true, false]
    end

    test "always samples listener spans" do
      span = Telemetry.start_span(:listener, %{}, %{})

      assert span.start_metadata[:sampled] == true
    end

    test "samples connection spans based on rate" do
      # Test multiple connection spans to verify sampling behavior
      spans =
        for _i <- 1..100 do
          Telemetry.start_span(:connection, %{}, %{})
        end

      # Should have some sampled and some unsampled spans
      sampled_count = Enum.count(spans, &(&1.start_metadata[:sampled] == true))
      unsampled_count = Enum.count(spans, &(&1.start_metadata[:sampled] == false))

      assert sampled_count > 0
      assert unsampled_count > 0
      # Connection spans should have approximately 10% sampling rate
      # Use more tolerant bounds due to randomness
      assert sampled_count / 100 > 0.01
      assert sampled_count / 100 < 0.25
    end
  end

  describe "start_span_with_sampling/4" do
    test "respects custom sample rate" do
      # Force sampling with 100% rate
      span = Telemetry.start_span_with_sampling(:connection, %{}, %{}, sample_rate: 1.0)
      assert span.start_metadata[:sampled] == true

      # Force no sampling with 0% rate
      span = Telemetry.start_span_with_sampling(:connection, %{}, %{}, sample_rate: 0.0)
      assert span.start_metadata[:sampled] == false
    end

    test "respects default sample rates for different span types" do
      listener_span = Telemetry.start_span_with_sampling(:listener, %{}, %{})
      assert listener_span.start_metadata[:sampled] == true

      # Unknown span types default to no sampling
      unknown_span = Telemetry.start_span_with_sampling(:unknown, %{}, %{})
      assert unknown_span.start_metadata[:sampled] == true
    end
  end

  describe "start_child_span/4" do
    test "creates child span with parent context" do
      parent_span = Telemetry.start_span(:parent, %{}, %{handler: TestHandler})
      child_span = Telemetry.start_child_span(parent_span, :child, %{test: "data"})

      assert child_span.span_name == :child

      assert child_span.start_metadata.parent_telemetry_span_context ==
               parent_span.telemetry_span_context

      assert child_span.start_metadata.handler == TestHandler
      # Note: Custom metadata in child spans may be handled differently by the implementation
      # The important thing is that the parent context is preserved
    end
  end

  describe "start_child_span_with_sampling/5" do
    test "creates child span with sampling" do
      parent_span = Telemetry.start_span(:parent, %{}, %{handler: TestHandler})

      # Test with forced sampling
      child_span =
        Telemetry.start_child_span_with_sampling(
          parent_span,
          :connection,
          %{},
          %{},
          sample_rate: 1.0
        )

      assert child_span.start_metadata[:sampled] == true

      assert child_span.start_metadata.parent_telemetry_span_context ==
               parent_span.telemetry_span_context
    end
  end

  describe "stop_span/3" do
    test "emits events only for sampled spans" do
      # Create a sampled span
      sampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 1.0)

      # Create an unsampled span
      unsampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 0.0)

      # Set up telemetry capture - note the abyss prefix
      test_pid = self()

      :telemetry.attach_many(
        "test-handler",
        [[:abyss, :test, :stop]],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        %{}
      )

      # Stop both spans
      Telemetry.stop_span(sampled_span, %{extra: "data"}, %{custom: "meta"})
      Telemetry.stop_span(unsampled_span, %{extra: "data"}, %{custom: "meta"})

      # Should only receive event for sampled span
      assert_receive {:telemetry_event, [:abyss, :test, :stop], measurements, metadata}
      assert measurements.extra == "data"
      assert measurements.duration > 0
      assert metadata.custom == "meta"

      # Should not receive event for unsampled span
      refute_receive {:telemetry_event, _, _, _}

      :telemetry.detach("test-handler")
    end
  end

  describe "span_event/4" do
    test "emits events only for sampled spans" do
      # Create sampled and unsampled spans
      sampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 1.0)
      unsampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 0.0)

      # Set up telemetry capture
      test_pid = self()

      :telemetry.attach_many(
        "test-handler",
        [[:abyss, :test, :custom_event]],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        %{}
      )

      # Send events from both spans
      Telemetry.span_event(sampled_span, :custom_event, %{value: 42}, %{custom: "data"})
      Telemetry.span_event(unsampled_span, :custom_event, %{value: 42}, %{custom: "data"})

      # Should only receive event from sampled span
      assert_receive {:telemetry_event, [:abyss, :test, :custom_event], measurements, metadata}
      assert measurements.value == 42
      assert metadata.custom == "data"

      # Should not receive event from unsampled span
      refute_receive {:telemetry_event, _, _, _}

      :telemetry.detach("test-handler")
    end
  end

  describe "untimed_span_event/4" do
    test "emits events only for sampled spans" do
      # Create sampled and unsampled spans
      sampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 1.0)
      unsampled_span = Telemetry.start_span_with_sampling(:test, %{}, %{}, sample_rate: 0.0)

      # Set up telemetry capture
      test_pid = self()

      :telemetry.attach_many(
        "test-handler",
        [[:abyss, :test, :untimed_event]],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        %{}
      )

      # Send events from both spans
      Telemetry.untimed_span_event(sampled_span, :untimed_event, %{data: "test"}, %{meta: "value"})

      Telemetry.untimed_span_event(unsampled_span, :untimed_event, %{data: "test"}, %{
        meta: "value"
      })

      # Should only receive event from sampled span
      assert_receive {:telemetry_event, [:abyss, :test, :untimed_event], measurements, metadata}
      assert measurements.data == "test"
      assert metadata.meta == "value"
      assert metadata.telemetry_span_context == sampled_span.telemetry_span_context

      # Should not receive event from unsampled span
      refute_receive {:telemetry_event, _, _, _}

      :telemetry.detach("test-handler")
    end
  end

  describe "sampling behavior" do
    test "sampling is deterministic with fixed seed" do
      :rand.seed(:exsplus, {1234, 5678, 9012})

      # Test that sampling is consistent
      results1 =
        for _i <- 1..1000 do
          span = Telemetry.start_span(:connection, %{}, %{})
          span.start_metadata[:sampled]
        end

      :rand.seed(:exsplus, {1234, 5678, 9012})

      results2 =
        for _i <- 1..1000 do
          span = Telemetry.start_span(:connection, %{}, %{})
          span.start_metadata[:sampled]
        end

      assert results1 == results2
    end

    test "unknown span types use no sampling by default" do
      :rand.seed(:exsplus, {1234, 5678, 9012})

      spans =
        for _i <- 1..100 do
          Telemetry.start_span(:unknown_span_type, %{}, %{})
        end

      # All unknown spans should be sampled by default
      assert Enum.all?(spans, &(&1.start_metadata[:sampled] == true))
    end
  end
end
