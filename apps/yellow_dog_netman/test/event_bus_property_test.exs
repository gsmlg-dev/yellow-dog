defmodule YellowDog.Netman.EventBusPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.EventBus

  @moduletag :capture_log

  defp topic_segment do
    gen all(segment <- string(:alphanumeric, min_length: 1, max_length: 10)) do
      segment
    end
  end

  defp topic_gen do
    gen all(segments <- list_of(topic_segment(), min_length: 2, max_length: 4)) do
      Enum.join(segments, ":")
    end
  end

  property "exact subscribers always receive published messages" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.publish(topic, message)
      assert_receive {:netman_event, ^topic, ^message}, 100
      EventBus.unsubscribe(topic)
    end
  end

  property "wildcard subscriber receives messages matching prefix" do
    check all(
            prefix <- topic_segment(),
            suffix <- topic_segment(),
            message <- term()
          ) do
      wildcard_topic = "prop_test:#{prefix}:*"
      specific_topic = "prop_test:#{prefix}:#{suffix}"

      {:ok, _} = EventBus.subscribe(wildcard_topic)
      EventBus.publish(specific_topic, message)
      assert_receive {:netman_event, ^specific_topic, ^message}, 100
      EventBus.unsubscribe(wildcard_topic)
    end
  end

  property "wildcard subscriber does not receive messages from different prefix" do
    check all(
            prefix_a <- topic_segment(),
            prefix_b <- topic_segment(),
            prefix_a != prefix_b,
            suffix <- topic_segment(),
            message <- term()
          ) do
      wildcard_topic = "prop_test:#{prefix_a}:*"
      other_topic = "prop_test:#{prefix_b}:#{suffix}"

      {:ok, _} = EventBus.subscribe(wildcard_topic)
      EventBus.publish(other_topic, message)
      refute_receive {:netman_event, ^other_topic, _}, 20
      EventBus.unsubscribe(wildcard_topic)
    end
  end

  property "publish order is preserved for a single subscriber" do
    check all(
            topic <- topic_gen(),
            messages <- list_of(integer(), min_length: 2, max_length: 20)
          ) do
      {:ok, _} = EventBus.subscribe(topic)

      Enum.each(messages, &EventBus.publish(topic, &1))

      received =
        Enum.map(messages, fn _msg ->
          receive do
            {:netman_event, ^topic, value} -> value
          after
            100 -> :timeout
          end
        end)

      assert received == messages
      EventBus.unsubscribe(topic)
    end
  end

  property "subscription to topic A never receives messages on unrelated topic B" do
    check all(
            topic_a <- topic_gen(),
            topic_b <- topic_gen(),
            topic_a != topic_b,
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic_a)
      EventBus.publish(topic_b, message)
      refute_receive {:netman_event, ^topic_b, _}, 30
      EventBus.unsubscribe(topic_a)
    end
  end

  property "unsubscribe stops delivery for exact subscriptions" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.unsubscribe(topic)

      # Publish after unsubscribe — should NOT be received
      EventBus.publish(topic, message)
      refute_receive {:netman_event, ^topic, _}, 30
    end
  end

  property "broadcast always returns :ok regardless of subscriber count" do
    check all(
            prefix <- topic_segment(),
            message <- term()
          ) do
      result = EventBus.broadcast("bc_prop:#{prefix}:", message)
      assert result == :ok
    end
  end

  property "broadcast delivers to subscriber whose topic starts with the prefix" do
    check all(
            prefix <- topic_segment(),
            suffix <- topic_segment(),
            message <- term()
          ) do
      topic = "bc_prop:#{prefix}:#{suffix}"

      {:ok, _} = EventBus.subscribe(topic)
      EventBus.broadcast("bc_prop:#{prefix}:", message)

      assert_receive {:netman_event, ^topic, ^message}, 100
      EventBus.unsubscribe(topic)
    end
  end

  property "broadcast does not deliver to subscriber with non-matching prefix" do
    check all(
            prefix_a <- topic_segment(),
            prefix_b <- topic_segment(),
            prefix_a != prefix_b,
            suffix <- topic_segment(),
            message <- term()
          ) do
      topic = "bc_prop:#{prefix_a}:#{suffix}"

      {:ok, _} = EventBus.subscribe(topic)
      EventBus.broadcast("bc_prop:#{prefix_b}:", message)

      refute_receive {:netman_event, ^topic, _}, 30
      EventBus.unsubscribe(topic)
    end
  end

  property "wildcard unsubscribe stops delivery for wildcard subscriptions" do
    check all(
            prefix <- topic_segment(),
            suffix <- topic_segment(),
            message <- term()
          ) do
      wildcard_topic = "prop_wu:#{prefix}:*"
      specific_topic = "prop_wu:#{prefix}:#{suffix}"

      {:ok, _} = EventBus.subscribe(wildcard_topic)
      EventBus.unsubscribe(wildcard_topic)

      # Publish after unsubscribe — wildcard should no longer receive it
      EventBus.publish(specific_topic, message)
      refute_receive {:netman_event, ^specific_topic, _}, 30
    end
  end

  property "subscribe always returns {:ok, _}" do
    check all(topic <- topic_gen()) do
      result = EventBus.subscribe(topic)
      assert match?({:ok, _}, result), "subscribe should return {:ok, _}, got: #{inspect(result)}"
      EventBus.unsubscribe(topic)
    end
  end

  property "publish always returns :ok" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      result = EventBus.publish(topic, message)
      assert result == :ok
    end
  end

  property "multiple subscribers on same topic each receive the same message" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      parent = self()

      task =
        Task.async(fn ->
          {:ok, _} = EventBus.subscribe(topic)
          send(parent, :subscribed)

          receive do
            {:netman_event, ^topic, ^message} -> :received
          after
            200 -> :timeout
          end
        end)

      assert_receive :subscribed, 500
      {:ok, _} = EventBus.subscribe(topic)

      EventBus.publish(topic, message)

      assert_receive {:netman_event, ^topic, ^message}, 200
      assert Task.await(task, 1000) == :received

      EventBus.unsubscribe(topic)
    end
  end

  property "late subscriber does not receive messages published before subscription" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      EventBus.publish(topic, message)
      {:ok, _} = EventBus.subscribe(topic)

      refute_receive {:netman_event, ^topic, ^message}, 50

      EventBus.unsubscribe(topic)
    end
  end
end
