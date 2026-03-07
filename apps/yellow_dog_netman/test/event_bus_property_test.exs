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

  property "publish to topic with no active subscribers always returns :ok" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      # Ensure no subscriber by unsubscribing first
      EventBus.unsubscribe(topic)

      result = EventBus.publish(topic, message)
      assert result == :ok,
             "Expected :ok when publishing to unsubscribed topic, got: #{inspect(result)}"
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

  property "concurrent subscribes from two processes both receive {:ok, _}" do
    check all(topic <- topic_gen()) do
      parent = self()

      t1 =
        Task.async(fn ->
          result = EventBus.subscribe(topic)
          send(parent, {:sub1, result})
          EventBus.unsubscribe(topic)
        end)

      t2 =
        Task.async(fn ->
          result = EventBus.subscribe(topic)
          send(parent, {:sub2, result})
          EventBus.unsubscribe(topic)
        end)

      Task.await(t1, 1000)
      Task.await(t2, 1000)

      assert_receive {:sub1, {:ok, _}}, 500
      assert_receive {:sub2, {:ok, _}}, 500
    end
  end

  property "re-subscribe after unsubscribe resumes delivery" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.unsubscribe(topic)

      # After unsubscribe, re-subscribe should restore delivery
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.publish(topic, message)
      assert_receive {:netman_event, ^topic, ^message}, 100

      EventBus.unsubscribe(topic)
    end
  end

  property "publish with atom message always delivers the atom unchanged" do
    check all(
            topic <- topic_gen(),
            atom <- StreamData.atom(:alphanumeric)
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.publish(topic, atom)

      assert_receive {:netman_event, ^topic, ^atom}, 100

      EventBus.unsubscribe(topic)
    end
  end

  property "after unsubscribe, published messages are not received" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.unsubscribe(topic)

      EventBus.publish(topic, message)

      refute_receive {:netman_event, ^topic, ^message}, 50
    end
  end

  property "after unsubscribe, subscribe to same topic still succeeds" do
    check all(topic <- topic_gen()) do
      EventBus.unsubscribe(topic)
      result = EventBus.subscribe(topic)
      assert match?({:ok, _}, result),
             "Expected subscribe to succeed after unsubscribe, got: #{inspect(result)}"
      EventBus.unsubscribe(topic)
    end
  end

  property "subscriber receives exactly one message per single publish call" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      {:ok, _} = EventBus.subscribe(topic)
      EventBus.publish(topic, message)

      assert_receive {:netman_event, ^topic, ^message}, 100
      refute_receive {:netman_event, ^topic, _}, 30

      EventBus.unsubscribe(topic)
    end
  end

  property "wildcard subscription receives events from multiple matching sub-topics" do
    check all(
            prefix <- topic_segment(),
            suffix1 <- topic_segment(),
            suffix2 <- topic_segment(),
            suffix1 != suffix2,
            msg1 <- term(),
            msg2 <- term()
          ) do
      wildcard = "wld_multi:#{prefix}:*"
      topic1 = "wld_multi:#{prefix}:#{suffix1}"
      topic2 = "wld_multi:#{prefix}:#{suffix2}"

      {:ok, _} = EventBus.subscribe(wildcard)
      EventBus.publish(topic1, msg1)
      EventBus.publish(topic2, msg2)

      assert_receive {:netman_event, ^topic1, ^msg1}, 200
      assert_receive {:netman_event, ^topic2, ^msg2}, 200

      EventBus.unsubscribe(wildcard)
    end
  end

  property "publish without any subscriber does not raise" do
    check all(
            topic <- topic_gen(),
            message <- term()
          ) do
      # Publish on a topic that nobody is subscribed to — must not raise
      result =
        try do
          EventBus.publish("nosub:#{topic}", message)
          :ok
        rescue
          e -> {:raised, e}
        end

      assert result == :ok,
             "Expected publish to be safe with no subscribers, got: #{inspect(result)}"
    end
  end

  property "subscribe returns {:ok, _} for any valid topic" do
    check all(topic <- topic_gen()) do
      result = EventBus.subscribe(topic)
      assert match?({:ok, _}, result),
             "Expected {:ok, _} from subscribe, got: #{inspect(result)}"
      EventBus.unsubscribe(topic)
    end
  end

  property "wildcard subscribe returns {:ok, _}" do
    check all(
            prefix <- topic_segment(),
            suffix <- topic_segment()
          ) do
      wildcard = "wc_sub:#{prefix}:#{suffix}:*"
      result = EventBus.subscribe(wildcard)
      assert match?({:ok, _}, result),
             "Expected {:ok, _} from wildcard subscribe, got: #{inspect(result)}"
      EventBus.unsubscribe(wildcard)
    end
  end

  property "unsubscribe after subscribe always returns :ok or nil" do
    check all(topic <- topic_gen()) do
      unique_topic = "ev_unsub:#{topic}:#{:rand.uniform(999_999)}"
      {:ok, _} = EventBus.subscribe(unique_topic)
      result = EventBus.unsubscribe(unique_topic)
      assert result == :ok or is_nil(result),
             "Expected :ok or nil from unsubscribe, got: #{inspect(result)}"
    end
  end

  property "publish always returns :ok regardless of message type" do
    check all(
            topic <- topic_gen(),
            msg <- StreamData.one_of([
              StreamData.integer(),
              StreamData.boolean(),
              StreamData.string(:alphanumeric, max_length: 20),
              StreamData.constant(nil),
              StreamData.constant(:ok)
            ])
          ) do
      result = EventBus.publish(topic, msg)
      assert result == :ok,
             "Expected :ok from publish, got: #{inspect(result)}"
    end
  end

  property "subscribe always returns {:ok, _} for any topic string" do
    check all(topic <- topic_gen()) do
      result = EventBus.subscribe(topic)
      assert match?({:ok, _}, result),
             "Expected {:ok, _} from subscribe, got: #{inspect(result)}"
      EventBus.unsubscribe(topic)
    end
  end
end
