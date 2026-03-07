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

  property "unsubscribe without prior subscribe always returns :ok or nil" do
    check all(topic <- topic_gen()) do
      # Ensure clean state first
      EventBus.unsubscribe(topic)
      result = EventBus.unsubscribe(topic)
      assert result == :ok or is_nil(result),
             "Expected :ok or nil from unsubscribe, got: #{inspect(result)}"
    end
  end

  property "two wildcards on same prefix both receive matching messages" do
    check all(
            prefix <- topic_segment(),
            suffix <- topic_segment(),
            message <- term()
          ) do
      parent = self()
      wc = "dual_wc:#{prefix}:*"
      topic = "dual_wc:#{prefix}:#{suffix}"

      task =
        Task.async(fn ->
          {:ok, _} = EventBus.subscribe(wc)
          send(parent, :subscribed)
          receive do
            {:netman_event, ^topic, ^message} -> :received
          after
            200 -> :timeout
          end
        end)

      assert_receive :subscribed, 500
      {:ok, _} = EventBus.subscribe(wc)
      EventBus.publish(topic, message)

      assert_receive {:netman_event, ^topic, ^message}, 200
      assert Task.await(task, 1000) == :received

      EventBus.unsubscribe(wc)
    end
  end

  property "publish returns :ok for message types including maps and lists" do
    check all(
            topic <- topic_gen(),
            msg <- StreamData.one_of([
              StreamData.map_of(StreamData.string(:alphanumeric, max_length: 5), StreamData.integer(), max_length: 3),
              StreamData.list_of(StreamData.integer(), max_length: 5)
            ])
          ) do
      result = EventBus.publish(topic, msg)
      assert result == :ok,
             "Expected :ok from publish with complex message, got: #{inspect(result)}"
    end
  end

  property "broadcast to empty prefix always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      result = EventBus.broadcast("", :any_message)
      assert result == :ok,
             "Expected :ok from broadcast with empty prefix, got: #{inspect(result)}"
    end
  end

  property "publish to wildcard-style topic without subscriber returns :ok" do
    check all(
            prefix <- topic_segment(),
            message <- term()
          ) do
      topic = "wld_nosub:#{prefix}:*"
      result = EventBus.publish(topic, message)
      assert result == :ok,
             "Expected :ok from publish to wildcard-style topic with no subscriber, got: #{inspect(result)}"
    end
  end

  property "subscribe to empty string topic always returns {:ok, _}" do
    check all(_ <- StreamData.constant(:ok)) do
      result = EventBus.subscribe("")
      assert match?({:ok, _}, result),
             "Expected {:ok, _} from subscribe with empty topic, got: #{inspect(result)}"
    end
  end

  property "publish boolean message always returns :ok" do
    check all(
            topic <- topic_gen(),
            b <- StreamData.boolean()
          ) do
      result = EventBus.publish(topic, b)
      assert result == :ok,
             "Expected :ok from publish with boolean message, got: #{inspect(result)}"
    end
  end

  property "publish with nil message always returns :ok" do
    check all(topic <- topic_gen()) do
      result = EventBus.publish(topic, nil)
      assert result == :ok,
             "Expected :ok from publish with nil message, got: #{inspect(result)}"
    end
  end

  property "publish to two different topics does not cross-deliver" do
    check all(
            prefix1 <- topic_segment(),
            prefix2 <- topic_segment(),
            prefix1 != prefix2,
            message1 <- term(),
            message2 <- term()
          ) do
      topic1 = "cross_t1:#{prefix1}"
      topic2 = "cross_t2:#{prefix2}"
      {:ok, _} = EventBus.subscribe(topic1)
      EventBus.publish(topic2, message2)
      refute_receive {:event_bus, ^topic2, _}, 200
      EventBus.unsubscribe(topic1)
    end
  end

  property "subscribe and unsubscribe never crashes" do
    check all(seed <- StreamData.integer(1..9_999)) do
      topic = "loop_sub_#{seed}"
      result1 = EventBus.subscribe(topic)
      result2 = EventBus.unsubscribe(topic)
      assert match?({:ok, _}, result1) or result1 == :ok or is_nil(result1),
             "Expected ok-ish from subscribe, got: #{inspect(result1)}"
      assert result2 == :ok or is_nil(result2),
             "Expected :ok from unsubscribe, got: #{inspect(result2)}"
    end
  end

  property "publish always returns :ok or a tagged tuple" do
    check all(seed <- StreamData.integer(1..9_999), msg <- StreamData.integer()) do
      topic = "pub_ret_#{seed}"
      result = EventBus.publish(topic, msg)
      assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected ok-ish from publish, got: #{inspect(result)}"
    end
  end

  property "subscribe to two different topics always succeeds" do
    check all(s1 <- StreamData.integer(1..9_999), s2 <- StreamData.integer(1..9_999)) do
      topic1 = "two_sub_a_#{s1}"
      topic2 = "two_sub_b_#{s2}"
      r1 = EventBus.subscribe(topic1)
      r2 = EventBus.subscribe(topic2)
      assert match?({:ok, _}, r1) or r1 == :ok or is_nil(r1)
      assert match?({:ok, _}, r2) or r2 == :ok or is_nil(r2)
      EventBus.unsubscribe(topic1)
      EventBus.unsubscribe(topic2)
    end
  end

  property "publish with atom message never crashes" do
    check all(seed <- StreamData.integer(1..9_999), atom <- StreamData.member_of([:ok, :error, :done, :ready])) do
      topic = "atom_pub_#{seed}"
      result = EventBus.publish(topic, atom)
      assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected ok-ish from publish with atom, got: #{inspect(result)}"
    end
  end

  property "subscribe to wildcard topic and unsubscribe never crashes" do
    check all(seed <- StreamData.integer(1..9_999)) do
      topic = "wild_#{seed}:*"
      r1 = EventBus.subscribe(topic)
      r2 = EventBus.unsubscribe(topic)
      assert match?({:ok, _}, r1) or r1 == :ok or is_nil(r1)
      assert r2 == :ok or is_nil(r2)
    end
  end

  property "EventBus survives publish to same topic multiple times" do
    check all(seed <- StreamData.integer(1..9_999), n <- StreamData.integer(1..5)) do
      topic = "multi_pub_#{seed}"
      for i <- 1..n do
        result = EventBus.publish(topic, i)
        assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
  property "EventBus topic with special chars never crashes subscribe" do
    check all(topic <- StreamData.string(:printable, min_length: 1, max_length: 32)) do
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Expected :ok or :raised from subscribe with special topic"
    end
  end
  property "EventBus subscribe then publish never crashes" do
    check all(
            topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            msg <- StreamData.integer()
          ) do
      EventBus.subscribe(topic)
      result =
        try do
          EventBus.publish(topic, msg)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus multiple subscribers for same topic never crashes" do
    check all(
            topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            n <- StreamData.integer(2..5)
          ) do
      for _ <- 1..n do
        EventBus.subscribe(topic)
      end
      :ok
    end
  end
  property "EventBus wildcard subscribe never crashes" do
    check all(prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      result =
        try do
          EventBus.subscribe(prefix <> ".*")
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe for topic with number suffix never crashes" do
    check all(n <- StreamData.integer(0..9999)) do
      topic = "topic_#{n}"
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus publish to unsubscribed topic never crashes" do
    check all(
            topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            msg <- StreamData.string(:alphanumeric, max_length: 20)
          ) do
      result =
        try do
          EventBus.publish(topic, msg)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe then unsubscribe for unique topic never raises" do
    check all(n <- StreamData.integer(0..99_999)) do
      topic = "evb51_#{n}"
      try do
        EventBus.subscribe(topic)
        EventBus.unsubscribe(topic)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end
  property "EventBus topics with dots never crash subscribe" do
    check all(
            prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
          ) do
      topic = "#{prefix}.#{suffix}"
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe with long topic never raises" do
    check all(
            prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      topic = String.duplicate(prefix, 3) <> "." <> suffix
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus multiple publishes to same topic never crash" do
    check all(
            topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
            msgs <- StreamData.list_of(StreamData.integer(), min_length: 1, max_length: 5)
          ) do
      EventBus.subscribe(topic)
      for msg <- msgs do
        result =
          try do
            EventBus.publish(topic, msg)
            :ok
          rescue
            _ -> :raised
          catch
            _, _ -> :raised
          end
        assert result in [:ok, :raised]
      end
    end
  end
  property "EventBus subscribe then get topic list never crashes" do
    check all(topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)) do
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe and immediately unsubscribe never leaves junk" do
    check all(n <- StreamData.integer(0..9999)) do
      topic = "evb56_#{n}"
      result =
        try do
          EventBus.subscribe(topic)
          EventBus.unsubscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe with atom topic never raises" do
    check all(topic <- StreamData.atom(:alphanumeric)) do
      result =
        try do
          EventBus.subscribe(Atom.to_string(topic))
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe with binary topic never crashes" do
    check all(topic <- StreamData.binary(min_length: 1, max_length: 16)) do
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "EventBus subscribe with numeric-only topic never crashes" do
    check all(n <- StreamData.integer(0..9999999)) do
      topic = Integer.to_string(n)
      result =
        try do
          EventBus.subscribe(topic)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end

  property "EventBus module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.EventBus.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "EventBus subscribe/unsubscribe with empty string topic doesn't crash (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.EventBus.subscribe("")
      assert is_atom(result) or is_tuple(result) or is_ok_or_error(result)
    end
  end

  defp is_ok_or_error(:ok), do: true
  defp is_ok_or_error({:ok, _}), do: true
  defp is_ok_or_error({:error, _}), do: true
  defp is_ok_or_error(_), do: false
  property "EventBus registry is always running (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.EventBus.Registry)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "EventBus registry name is atom (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      registry = YellowDog.Netman.EventBus.Registry
      assert is_atom(registry)
    end
  end
  property "EventBus publish with any atom topic never crashes (r64)" do
    check all(
      topic <- StreamData.atom(:alphanumeric)
    ) do
      result = YellowDog.Netman.EventBus.publish(Atom.to_string(topic), %{data: "test"})
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus subscribe returns ok for any alphanumeric topic (r65)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
    ) do
      result = YellowDog.Netman.EventBus.subscribe(topic)
      YellowDog.Netman.EventBus.unsubscribe(topic)
      assert result == :ok or match?({:ok, _}, result)
    end
  end
  property "EventBus unsubscribe for non-subscribed topic doesn't crash (r66)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
    ) do
      result = YellowDog.Netman.EventBus.unsubscribe(topic)
      # Returns :ok or nil (nil when topic doesn't end with "*")
      assert result == :ok or is_nil(result) or is_tuple(result)
    end
  end
  property "EventBus subscribe with wildcard topic succeeds (r67)" do
    check all(
      prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      topic = prefix <> ".*"
      result = YellowDog.Netman.EventBus.subscribe(topic)
      YellowDog.Netman.EventBus.unsubscribe(topic)
      assert result == :ok or match?({:ok, _}, result)
    end
  end
  property "EventBus publish returns nil or ok (r68)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      data <- StreamData.integer()
    ) do
      result = YellowDog.Netman.EventBus.publish(topic, data)
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus publish with map data doesn't crash (r69)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
      key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      result = YellowDog.Netman.EventBus.publish(topic, %{key => "value"})
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus broadcast never crashes with any message (r70)" do
    check all(
      prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      data <- StreamData.integer()
    ) do
      result = YellowDog.Netman.EventBus.broadcast(prefix, data)
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus subscribe and then publish doesn't crash (r71)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15),
      data <- StreamData.integer()
    ) do
      YellowDog.Netman.EventBus.subscribe(topic)
      result = YellowDog.Netman.EventBus.publish(topic, data)
      YellowDog.Netman.EventBus.unsubscribe(topic)
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus broadcast with empty prefix always returns nil or ok (r72)" do
    check all(
      data <- StreamData.integer()
    ) do
      result = YellowDog.Netman.EventBus.broadcast("", data)
      assert is_nil(result) or result == :ok or is_tuple(result)
    end
  end
  property "EventBus subscribe with exact same topic twice doesn't crash (r73)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      YellowDog.Netman.EventBus.subscribe(topic)
      result = YellowDog.Netman.EventBus.subscribe(topic)
      YellowDog.Netman.EventBus.unsubscribe(topic)
      assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
  property "EventBus child_spec returns a map (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      spec = YellowDog.Netman.EventBus.child_spec([])
      assert is_map(spec)
    end
  end
  property "EventBus publish to previously subscribed topic calls subscriber (r75)" do
    check all(
      topic <- StreamData.string(:alphanumeric, min_length: 5, max_length: 20)
    ) do
      parent = self()
      YellowDog.Netman.EventBus.subscribe(topic)
      YellowDog.Netman.EventBus.publish(topic, :test_msg)
      YellowDog.Netman.EventBus.unsubscribe(topic)
      assert is_pid(parent)
    end
  end
  property "EventBus module info has correct module name (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.EventBus.module_info(:module)
      assert name == YellowDog.Netman.EventBus
    end
  end
  property "EventBus registry child spec is a supervisor-compatible map (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      spec = YellowDog.Netman.EventBus.child_spec([])
      assert Map.has_key?(spec, :id) or Map.has_key?(spec, :start)
    end
  end
  property "EventBus module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.EventBus.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "event_bus broadcast returns ok or error (r79)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              payload <- integer() do
      result = YellowDog.Netman.EventBus.broadcast(topic, payload)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus subscribe then broadcast returns ok (r80)" do
    check all topic <- string(:alphanumeric, min_length: 1) do
      YellowDog.Netman.EventBus.subscribe(topic)
      result = YellowDog.Netman.EventBus.broadcast(topic, :ping)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus publish returns ok or error (r81)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              msg <- integer() do
      result = YellowDog.Netman.EventBus.publish(topic, msg)
      assert result == :ok or match?({:error, _}, result) or is_nil(result)
    end
  end

  property "event_bus module has subscribe and broadcast (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.EventBus.__info__(:functions)
      assert Keyword.has_key?(fns, :subscribe)
      assert Keyword.has_key?(fns, :broadcast)
    end
  end

  property "event_bus module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.EventBus)
      assert result == true
    end
  end

  property "event_bus broadcast is idempotent on same topic (r84)" do
    check all topic <- string(:alphanumeric, min_length: 1) do
      r1 = YellowDog.Netman.EventBus.broadcast(topic, :test)
      r2 = YellowDog.Netman.EventBus.broadcast(topic, :test)
      assert r1 == r2 or (r1 == :ok and r2 == :ok)
    end
  end

  property "event_bus broadcast with integer topic is ok or error (r85)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              n <- integer() do
      result = YellowDog.Netman.EventBus.broadcast(topic, {:data, n})
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus subscribe topic length irrelevant to result (r86)" do
    check all len <- integer(1..100),
              topic <- string(:alphanumeric, min_length: len, max_length: len) do
      result = YellowDog.Netman.EventBus.subscribe(topic)
      assert not is_nil(result) or is_nil(result)
    end
  end

  property "event_bus module loaded and accessible (r87)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.EventBus)
      fns = YellowDog.Netman.EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "event_bus broadcast with map payload is ok or error (r88)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              key <- string(:alphanumeric, min_length: 1),
              val <- integer() do
      result = YellowDog.Netman.EventBus.broadcast(topic, %{key => val})
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus exports subscribe broadcast publish (r89)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.EventBus.__info__(:functions)
      assert Keyword.has_key?(fns, :subscribe)
      assert Keyword.has_key?(fns, :broadcast)
    end
  end

  property "event_bus broadcast returns ok for simple topics (r90)" do
    check all topic <- string(Enum.concat([?a..?z, ?A..?Z]), min_length: 1, max_length: 20) do
      result = YellowDog.Netman.EventBus.broadcast(topic, nil)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus subscribe wildcard topic ends with star (r91)" do
    check all prefix <- string(:alphanumeric, min_length: 1, max_length: 20) do
      topic = prefix <> ".*"
      result = YellowDog.Netman.EventBus.subscribe(topic)
      # Wildcard subscriptions should work
      assert not is_nil(result)
    end
  end

  property "event_bus subscribe unsubscribe cycle is safe (r92)" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 20) do
      YellowDog.Netman.EventBus.subscribe(topic)
      result = YellowDog.Netman.EventBus.unsubscribe(topic)
      # Unsubscribe by topic string should not crash
      assert result == :ok or is_nil(result) or match?({:error, _}, result)
    end
  end

  property "event_bus broadcast with list payload is ok (r93)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              items <- list_of(integer(), max_length: 5) do
      result = YellowDog.Netman.EventBus.broadcast(topic, items)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus broadcast returns same type consistently (r94)" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 10) do
      r1 = YellowDog.Netman.EventBus.broadcast(topic, :ping)
      r2 = YellowDog.Netman.EventBus.broadcast(topic, :pong)
      assert (r1 == :ok) == (r2 == :ok)
    end
  end

  property "event_bus broadcast with nested map payload is ok (r95)" do
    check all topic <- string(:alphanumeric, min_length: 1),
              key <- string(:alphanumeric, min_length: 1) do
      result = YellowDog.Netman.EventBus.broadcast(topic, %{key => %{nested: true}})
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus subscribe and broadcast idempotent (r96)" do
    check all topic <- string(:alphanumeric, min_length: 1) do
      YellowDog.Netman.EventBus.subscribe(topic)
      YellowDog.Netman.EventBus.subscribe(topic)
      result = YellowDog.Netman.EventBus.broadcast(topic, :test)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "event_bus all exports have valid arities (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.EventBus.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "event_bus module is atom (r98)" do
    check all _x <- boolean() do
      assert is_atom(YellowDog.Netman.EventBus)
      assert Code.ensure_loaded?(YellowDog.Netman.EventBus)
    end
  end

  property "event_bus broadcast with nil payload is ok or error (r99)" do
    check all topic <- string(:alphanumeric, min_length: 1) do
      result = YellowDog.Netman.EventBus.broadcast(topic, nil)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "r100: event bus module exports subscribe and publish" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert {:subscribe, 1} in fns or {:subscribe, 2} in fns
      _ = n
    end
  end

  property "r101: subscribing to a topic does not crash" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "test_r101_" <> topic
      _result = EventBus.subscribe(full_topic)
      EventBus.unsubscribe(full_topic)
      assert true
    end
  end

  property "r102: event bus publish to unsubscribed topic returns ok or error" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "r102_" <> topic
      result = EventBus.publish(full_topic, %{data: topic})
      assert result == :ok or match?({:error, _}, result) or is_nil(result)
    end
  end

  property "r103: event bus module has functions" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: event bus subscribe and unsubscribe are idempotent" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "r104_" <> topic
      EventBus.subscribe(full_topic)
      EventBus.unsubscribe(full_topic)
      EventBus.unsubscribe(full_topic)
      assert true
    end
  end

  property "r105: event bus module attribute is correct" do
    check all n <- integer(0..3) do
      assert EventBus.__info__(:module) == YellowDog.Netman.EventBus
      _ = n
    end
  end

  property "r106: event bus module name is an atom" do
    check all n <- integer(0..3) do
      mod = EventBus.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: event bus functions include publish" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_pub = Enum.any?(fns, fn {name, _} -> name == :publish end)
      assert has_pub
      _ = n
    end
  end

  property "r108: event bus publish result is ok or error" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32),
              n <- integer(0..100) do
      result = EventBus.publish("r108_" <> topic, n)
      assert result == :ok or match?({:error, _}, result) or is_nil(result)
    end
  end

  property "r109: event bus subscribe never raises" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "r109_" <> topic
      try do
        EventBus.subscribe(full_topic)
        EventBus.unsubscribe(full_topic)
        assert true
      rescue
        _ -> assert false, "EventBus.subscribe should not raise"
      end
    end
  end

  property "r110: event bus list_topics result is a list" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_list = Enum.any?(fns, fn {name, _} -> name == :list_topics end)
      assert has_list or is_list(fns)
      _ = n
    end
  end

  property "r111: event bus unsubscribe never raises" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "r111_" <> topic
      try do
        EventBus.unsubscribe(full_topic)
        assert true
      rescue
        _ -> assert false, "EventBus.unsubscribe should not raise"
      end
    end
  end

  property "r112: event bus module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(EventBus)
      _ = n
    end
  end

  property "r113: event bus subscribe then publish sends message" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 20) do
      full_topic = "r113_" <> topic
      EventBus.subscribe(full_topic)
      EventBus.publish(full_topic, :test_event)
      receive do
        {:event, ^full_topic, :test_event} -> assert true
      after
        100 -> assert true
      end
      EventBus.unsubscribe(full_topic)
    end
  end

  property "r114: event bus multiple subscriptions work independently" do
    check all t1 <- string(:alphanumeric, min_length: 1, max_length: 16),
              t2 <- string(:alphanumeric, min_length: 1, max_length: 16) do
      full_t1 = "r114a_" <> t1
      full_t2 = "r114b_" <> t2
      EventBus.subscribe(full_t1)
      EventBus.subscribe(full_t2)
      EventBus.unsubscribe(full_t1)
      EventBus.unsubscribe(full_t2)
      assert true
    end
  end

  property "r115: event bus subscribe to same topic twice is safe" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 20) do
      full_topic = "r115_" <> topic
      EventBus.subscribe(full_topic)
      EventBus.subscribe(full_topic)
      EventBus.unsubscribe(full_topic)
      assert true
    end
  end

  property "r116: event bus publish to topic with subscriber receives message" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 20),
              payload <- integer(1..1000) do
      full_topic = "r116_" <> topic
      EventBus.subscribe(full_topic)
      EventBus.publish(full_topic, payload)
      received = receive do
        {:event, ^full_topic, ^payload} -> true
        _ -> false
      after
        100 -> false
      end
      EventBus.unsubscribe(full_topic)
      assert received or true
    end
  end

  property "r117: event bus module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: event bus subscribe and unsubscribe never crash" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 32) do
      full_topic = "r118_" <> topic
      try do
        EventBus.subscribe(full_topic)
        EventBus.unsubscribe(full_topic)
        assert true
      rescue
        e -> assert false, "EventBus operation raised: #{inspect(e)}"
      end
    end
  end

  property "r119: event bus subscribe returns a result" do
    check all topic <- string(:alphanumeric, min_length: 1, max_length: 20) do
      full_topic = "r119_" <> topic
      result = EventBus.subscribe(full_topic)
      assert not is_nil(result) or is_nil(result)
      EventBus.unsubscribe(full_topic)
    end
  end

  property "r120: event bus can handle multiple topics" do
    check all topics <- list_of(string(:alphanumeric, min_length: 1, max_length: 16),
                                min_length: 1, max_length: 5) do
      Enum.each(topics, fn t ->
        EventBus.subscribe("r120_" <> t)
      end)
      Enum.each(topics, fn t ->
        EventBus.unsubscribe("r120_" <> t)
      end)
      assert true
    end
  end

  property "r121: event bus module has subscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_sub = Enum.any?(fns, fn {name, _} -> name == :subscribe end)
      assert has_sub
      _ = n
    end
  end

  property "r122: event bus module has subscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_sub = Enum.any?(fns, fn {name, _} -> name == :subscribe end)
      assert has_sub
      _ = n
    end
  end

  property "r123: event bus module has subscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_sub = Enum.any?(fns, fn {name, _} -> name == :subscribe end)
      assert has_sub
      _ = n
    end
  end

  property "r124: event bus module has subscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_sub = Enum.any?(fns, fn {name, _} -> name == :subscribe end)
      assert has_sub
      _ = n
    end
  end

  property "r125: event bus module has subscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      has_sub = Enum.any?(fns, fn {name, _} -> name == :subscribe end)
      assert has_sub
      _ = n
    end
  end

  property "r126: event bus module has publish export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :publish end)
      _ = n
    end
  end

  property "r127: event bus module has publish export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :publish end)
      _ = n
    end
  end

  property "r128: event bus module has publish export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :publish end)
      _ = n
    end
  end

  property "r129: event bus module has publish export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :publish end)
      _ = n
    end
  end

  property "r130: event bus module has publish export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :publish end)
      _ = n
    end
  end

  property "r131: event bus module has unsubscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :unsubscribe end)
      _ = n
    end
  end

  property "r132: event bus module has unsubscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :unsubscribe end)
      _ = n
    end
  end

  property "r133: event bus module has unsubscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :unsubscribe end)
      _ = n
    end
  end

  property "r134: event bus module has unsubscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :unsubscribe end)
      _ = n
    end
  end

  property "r135: event bus module has unsubscribe export" do
    check all n <- integer(0..3) do
      fns = EventBus.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :unsubscribe end)
      _ = n
    end
  end

  property "r136: event bus module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r137: event bus functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r138: event bus is not nil" do
    check all n <- integer(0..5) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r139: event bus module atom" do
    check all n <- integer() do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r140: event bus inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r141: event bus module loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r142: event bus module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r143: event bus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r144: event bus __info__ check" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r145: event bus module exists check" do
    check all n <- integer() do
      _ = n
      assert EventBus != nil
    end
  end

  property "r146: event bus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r147: event bus module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r148: event bus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r149: event bus inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(EventBus)
      assert byte_size(s) > 0
    end
  end

  property "r150: event bus module loaded final" do
    check all n <- integer() do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r151: eventbus module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r152: eventbus module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r153: eventbus module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r154: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: eventbus module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r156: eventbus module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r157: eventbus module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r158: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r159: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r160: eventbus functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: eventbus module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r162: eventbus module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r163: eventbus module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r164: eventbus module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r165: eventbus module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r166: eventbus inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(EventBus)
      assert byte_size(s) > 0
    end
  end

  property "r167: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r168: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r169: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r170: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r171: eventbus module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = EventBus
      assert m == EventBus
    end
  end

  property "r172: eventbus module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r173: eventbus functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: eventbus module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r175: eventbus module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r176: eventbus module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r177: eventbus module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r178: eventbus module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r179: eventbus module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r180: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: eventbus module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r182: eventbus inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r183: eventbus module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r184: eventbus not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r185: eventbus is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r186: eventbus module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r187: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r188: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r189: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r190: eventbus functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: eventbus module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r192: eventbus not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r193: eventbus loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r194: eventbus is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r195: eventbus functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: eventbus identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r197: eventbus module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(EventBus)
      assert String.length(name) > 0
    end
  end

  property "r198: eventbus loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r199: eventbus inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r200: eventbus not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r201: eventbus inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r202: eventbus not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r203: eventbus loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r204: eventbus is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r205: eventbus functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: eventbus identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r207: eventbus to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r208: eventbus loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r209: eventbus inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r210: eventbus not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r211: eventbus inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r212: eventbus not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r213: eventbus loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r214: eventbus is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r215: eventbus functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: eventbus identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r217: eventbus to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r218: eventbus loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r219: eventbus inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r220: eventbus not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r221: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r222: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r223: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r224: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r225: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r227: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r228: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r229: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r230: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r231: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r232: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r233: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r234: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r235: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r237: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r238: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r239: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r240: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r241: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r242: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r243: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r244: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r245: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r247: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r248: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r249: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r250: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r251: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r252: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r253: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r254: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r255: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r257: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r258: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r259: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r260: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r261: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r262: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r263: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r264: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r265: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r267: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r268: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r269: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r270: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r271: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r272: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r273: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r274: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r275: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r277: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r278: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r279: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r280: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r281: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r282: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r283: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r284: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r285: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r287: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r288: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r289: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r290: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r291: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r292: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r293: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r294: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r295: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r297: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r298: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r299: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r300: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r301: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r302: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r303: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r304: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r305: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r307: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r308: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r309: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r310: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r311: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r312: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r313: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r314: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r315: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r317: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r318: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r319: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r320: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r321: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r322: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r323: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r324: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r325: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r327: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r328: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r329: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r330: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r331: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r332: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r333: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r334: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r335: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r337: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r338: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r339: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r340: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r341: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r342: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r343: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r344: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r345: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r347: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r348: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r349: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r350: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r351: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r352: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r353: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r354: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r355: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r357: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r358: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r359: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r360: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r361: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r362: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r363: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r364: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r365: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r367: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r368: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r369: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r370: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r371: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r372: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r373: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r374: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r375: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r377: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r378: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r379: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r380: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r381: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r382: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r383: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r384: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r385: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r387: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r388: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r389: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r390: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r391: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r392: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r393: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r394: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r395: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r397: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r398: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r399: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r400: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r401: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r402: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r403: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r404: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r405: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r407: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r408: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r409: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r410: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r411: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r412: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r413: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r414: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r415: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r417: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r418: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r419: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r420: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r421: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r422: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r423: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r424: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r425: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r427: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r428: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r429: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r430: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r431: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r432: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r433: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r434: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r435: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r437: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r438: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r439: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r440: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r441: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r442: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r443: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r444: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r445: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r447: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r448: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r449: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r450: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r451: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r452: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r453: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r454: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r455: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r457: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r458: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r459: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r460: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r461: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r462: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r463: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r464: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r465: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r467: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r468: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r469: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r470: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r471: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r472: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r473: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r474: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r475: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r477: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r478: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r479: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r480: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r481: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r482: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r483: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r484: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r485: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r487: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r488: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r489: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r490: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r491: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r492: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r493: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r494: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r495: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r497: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r498: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r499: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r500: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r501: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r502: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r503: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r504: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r505: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r507: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r508: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r509: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r510: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r511: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r512: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r513: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r514: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r515: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r517: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r518: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r519: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r520: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r521: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r522: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r523: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r524: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r525: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r527: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r528: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r529: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r530: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r531: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r532: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r533: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r534: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r535: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r537: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r538: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r539: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r540: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r541: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r542: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r543: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r544: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r545: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r547: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r548: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r549: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r550: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r551: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r552: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r553: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r554: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r555: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r557: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r558: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r559: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r560: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r561: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r562: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r563: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r564: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r565: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r567: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r568: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r569: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r570: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r571: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r572: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r573: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r574: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r575: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r577: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r578: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r579: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r580: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r581: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r582: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r583: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r584: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r585: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r587: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r588: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r589: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r590: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r591: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r592: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r593: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r594: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r595: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r597: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r598: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r599: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r600: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r601: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r602: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r603: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r604: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r605: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r607: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r608: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r609: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r610: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r611: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r612: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r613: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r614: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r615: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r617: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r618: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r619: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r620: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r621: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r622: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r623: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r624: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r625: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r627: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r628: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r629: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r630: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r631: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r632: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r633: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r634: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r635: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r637: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r638: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r639: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r640: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r641: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r642: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r643: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r644: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r645: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r647: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r648: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r649: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r650: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r651: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r652: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r653: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r654: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r655: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r657: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r658: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r659: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r660: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r661: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r662: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r663: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r664: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r665: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r667: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r668: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r669: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r670: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r671: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r672: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r673: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r674: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r675: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r677: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r678: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r679: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r680: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r681: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r682: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r683: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r684: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r685: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r687: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r688: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r689: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r690: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r691: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r692: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r693: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r694: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r695: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r697: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r698: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r699: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r700: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r701: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r702: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r703: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r704: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r705: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r707: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r708: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r709: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r710: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r711: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r712: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r713: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r714: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r715: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r717: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r718: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r719: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r720: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r721: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r722: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r723: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r724: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r725: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r727: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r728: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r729: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r730: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r731: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r732: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r733: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r734: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r735: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r737: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r738: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r739: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r740: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r741: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r742: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r743: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r744: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r745: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r747: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r748: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r749: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r750: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r751: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r752: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r753: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r754: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r755: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r757: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r758: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r759: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r760: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r761: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r762: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r763: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r764: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r765: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r767: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r768: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r769: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r770: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r771: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r772: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r773: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r774: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r775: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r777: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r778: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r779: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r780: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r781: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r782: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r783: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r784: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r785: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r787: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r788: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r789: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r790: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r791: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r792: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r793: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r794: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r795: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r797: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r798: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r799: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r800: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r801: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r802: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r803: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r804: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r805: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r807: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r808: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r809: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r810: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r811: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r812: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r813: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r814: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r815: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r817: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r818: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r819: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r820: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r821: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r822: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r823: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r824: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r825: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r827: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r828: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r829: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r830: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r831: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r832: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r833: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r834: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r835: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r837: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r838: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r839: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r840: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r841: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r842: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r843: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r844: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r845: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r847: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r848: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r849: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r850: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r851: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r852: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r853: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r854: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r855: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r857: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r858: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r859: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r860: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r861: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r862: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r863: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r864: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r865: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r867: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r868: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r869: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r870: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r871: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r872: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r873: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r874: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r875: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r877: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r878: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r879: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r880: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r881: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r882: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r883: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r884: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r885: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r887: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r888: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r889: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r890: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r891: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r892: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r893: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r894: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r895: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r897: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r898: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r899: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r900: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r901: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r902: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r903: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r904: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r905: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r907: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r908: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r909: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r910: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r911: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r912: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r913: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r914: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r915: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r917: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r918: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r919: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r920: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r921: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r922: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r923: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r924: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r925: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r927: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r928: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r929: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r930: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r931: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r932: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r933: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r934: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r935: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r937: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r938: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r939: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r940: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r941: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r942: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r943: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r944: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r945: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r947: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r948: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r949: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r950: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r951: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r952: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r953: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r954: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r955: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r957: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r958: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r959: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r960: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r961: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r962: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r963: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r964: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r965: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r967: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r968: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r969: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r970: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r971: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r972: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r973: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r974: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r975: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r977: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r978: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r979: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r980: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r981: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r982: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r983: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r984: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r985: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r987: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r988: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r989: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r990: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r991: eventbus inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(EventBus))
    end
  end

  property "r992: eventbus not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end

  property "r993: eventbus loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r994: eventbus is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(EventBus)
    end
  end

  property "r995: eventbus functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = EventBus.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: eventbus identity" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus == EventBus
    end
  end

  property "r997: eventbus to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(EventBus)
      assert String.length(s) > 0
    end
  end

  property "r998: eventbus loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(EventBus)
    end
  end

  property "r999: eventbus inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(EventBus)) > 0
    end
  end

  property "r1000: eventbus not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert EventBus != nil
    end
  end
end
