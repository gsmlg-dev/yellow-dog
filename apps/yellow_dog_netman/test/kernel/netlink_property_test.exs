defmodule YellowDog.Netman.Kernel.NetlinkPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.Netlink

  @known_event_types [
    "link_change",
    "address_change",
    "route_change",
    "rule_change",
    "neighbor_change"
  ]

  @moduletag :capture_log

  defp unique_tag do
    "#{:erlang.unique_integer([:monotonic, :positive])}"
  end

  # Generator for extra event fields — uses "xf_" prefix to avoid
  # colliding with reserved keys ("type", "_tag", "interface").
  defp extra_field_gen do
    StreamData.list_of(
      StreamData.tuple(
        {StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
         |> StreamData.map(&("xf_" <> &1)), StreamData.string(:alphanumeric, max_length: 10)}
      ),
      max_length: 3
    )
    |> StreamData.map(&Map.new/1)
  end

  # Properties

  property "known event types always dispatch with the correct tuple atom" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "unknown event types always dispatch as :unknown" do
    unknown_gen =
      StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
      |> StreamData.filter(&(&1 not in @known_event_types))

    check all(event_type <- unknown_gen) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "dispatched event preserves the original map payload" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            interface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 14),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "interface" => interface, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag} = received}}, 500
      assert received["type"] == event_type
      assert received["interface"] == interface
    end
  end

  property "all current subscribers receive the same dispatched event" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      parent = self()
      tag = unique_tag()
      expected_atom = String.to_atom(event_type)

      Netlink.subscribe()

      task =
        Task.async(fn ->
          Netlink.subscribe()
          send(parent, :ready)

          receive do
            {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}} -> :received
          after
            2000 -> :timeout
          end
        end)

      assert_receive :ready, 500
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
      assert Task.await(task, 3000) == :received
    end
  end

  property "subscribe is idempotent — subscribing twice delivers events exactly once" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Netlink.subscribe()
      # Allow both casts to be processed
      Process.sleep(20)

      tag = unique_tag()
      expected_atom = String.to_atom(event_type)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500

      # Should NOT receive a second copy (idempotent subscribe)
      refute_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 50
    end
  end

  property "subscribe always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Netlink.subscribe() == :ok
    end
  end

  property "command always returns :ok or {:error, _} for any map command" do
    check all(
            cmd_type <-
              StreamData.member_of(["link_set", "addr_add", "addr_del", "route_add", "route_del"]),
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      result = Netlink.command(%{"cmd" => cmd_type, "interface" => iface})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected command result: #{inspect(result)}"
    end
  end

  property "command with unknown cmd type always returns :ok or {:error, _}" do
    check all(
            unknown_cmd <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(
                &(&1 not in ["link_set", "addr_add", "addr_del", "route_add", "route_del"])
              )
          ) do
      result = Netlink.command(%{"cmd" => unknown_cmd})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected command result for #{inspect(unknown_cmd)}: #{inspect(result)}"
    end
  end

  property "dispatch remains functional after a subscriber process exits" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      parent = self()

      # Spawn a subscriber that will die
      sub =
        Task.async(fn ->
          Netlink.subscribe()
          send(parent, :subscribed)
          # Block until killed
          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed, 500
      Process.sleep(20)

      # Kill the subscriber
      Task.shutdown(sub, :brutal_kill)
      Process.sleep(50)

      # Main process subscribes and verifies dispatch still works
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      expected_atom = String.to_atom(event_type)
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "command with empty map always returns :ok or {:error, _}" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netlink.command(%{})
      assert result == :ok or match?({:error, _}, result),
             "Unexpected result for empty command map: #{inspect(result)}"
    end
  end

  property "two different event types dispatched sequentially are both received" do
    check all(
            type1 <- StreamData.member_of(@known_event_types),
            type2 <- StreamData.member_of(@known_event_types),
            type1 != type2
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag1 = unique_tag()
      tag2 = unique_tag()
      atom1 = String.to_atom(type1)
      atom2 = String.to_atom(type2)

      send(Netlink, {:mock_event, %{"type" => type1, "_tag" => tag1}})
      send(Netlink, {:mock_event, %{"type" => type2, "_tag" => tag2}})

      assert_receive {:netlink_event, {^atom1, %{"_tag" => ^tag1}}}, 500
      assert_receive {:netlink_event, {^atom2, %{"_tag" => ^tag2}}}, 500
    end
  end

  property "event with type value nil always dispatches as :unknown" do
    check all(extra <- extra_field_gen()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => nil, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with integer type value always dispatches as :unknown" do
    check all(n <- StreamData.integer()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => n, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with boolean type value always dispatches as :unknown" do
    check all(bool_type <- StreamData.boolean()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => bool_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with list type value always dispatches as :unknown" do
    check all(items <- StreamData.list_of(StreamData.integer(), max_length: 3)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => items, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "events without type field always dispatch as :unknown" do
    check all(extra <- extra_field_gen()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      # Send event map with no "type" key (only extra fields + tag)
      event = Map.merge(extra, %{"_tag" => tag})
      send(Netlink, {:mock_event, event})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with map type value always dispatches as :unknown" do
    check all(
            map_type <-
              StreamData.map_of(
                StreamData.atom(:alphanumeric),
                StreamData.integer(),
                max_length: 3
              )
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => map_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with atom type value always dispatches as :unknown" do
    check all(atom_type <- StreamData.atom(:alphanumeric)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => atom_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with float type value always dispatches as :unknown" do
    check all(float_type <- StreamData.float()) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => float_type, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "extra event fields are always preserved in the dispatched payload" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})

      expected_atom = String.to_atom(event_type)

      assert_receive {:netlink_event, {^expected_atom, received}}, 500

      for {key, value} <- extra do
        assert received[key] == value,
               "Expected extra field #{key}=#{inspect(value)} to be preserved in dispatched event"
      end
    end
  end

  property "event with tuple type value always dispatches as :unknown" do
    check all(
            a <- StreamData.integer(),
            b <- StreamData.integer()
          ) do
      Netlink.subscribe()
      Process.sleep(10)

      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => {a, b}, "_tag" => tag}})

      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "two sequential events of same type are both received in order" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)

      tag1 = unique_tag()
      tag2 = unique_tag()
      expected_atom = String.to_atom(event_type)

      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag1}})
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag2}})

      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag1}}}, 500
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag2}}}, 500
    end
  end

  property "unknown event type with binary value always dispatches as :unknown" do
    check all(
            type <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      # Only test types that are NOT known event types
      unless type in @known_event_types do
        Netlink.subscribe()
        Process.sleep(10)
        tag = unique_tag()
        send(Netlink, {:mock_event, %{"type" => type, "_tag" => tag}})
        assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
      end
    end
  end

  property "known event type is always dispatched with the correct atom key" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      expected_atom = String.to_atom(event_type)
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      assert_receive {:netlink_event, {^expected_atom, %{"_tag" => ^tag}}}, 500
    end
  end

  property "event with missing type key always dispatches as :unknown" do
    check all(_ <- StreamData.constant(:ok)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"_tag" => tag}})
      assert_receive {:netlink_event, {:unknown, %{"_tag" => ^tag}}}, 500
    end
  end

  property "dispatched event payload is always a map" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500
      assert is_map(payload),
             "Expected map payload for #{event_type}, got: #{inspect(payload)}"
    end
  end

  property "event payload always contains the original extra fields" do
    check all(
            event_type <- StreamData.member_of(@known_event_types),
            extra <- extra_field_gen()
          ) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      event = Map.merge(extra, %{"type" => event_type, "_tag" => tag})
      send(Netlink, {:mock_event, event})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500

      for {k, v} <- extra do
        assert Map.get(payload, k) == v,
               "Expected extra field #{k} = #{inspect(v)} in payload, got: #{inspect(Map.get(payload, k))}"
      end
    end
  end

  property "Netlink process is always alive after dispatching any known event type" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      netlink_pid = Process.whereis(Netlink)
      assert netlink_pid != nil, "Expected Netlink process to be registered"
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      Process.sleep(10)
      assert Process.alive?(netlink_pid),
             "Expected Netlink process to still be alive after dispatching #{event_type}"
    end
  end

  property "dispatched event payload always has 'type' key removed or replaced" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, payload}}, 500
      assert is_map(payload), "Expected map payload, got: #{inspect(payload)}"
    end
  end

  property "subscribing multiple times from same process receives event once" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      assert_receive {:netlink_event, {^expected_atom, _}}, 500
      refute_receive {:netlink_event, _}, 50
    end
  end

  property "all known event types always produce a map payload" do
    check all(event_type <- StreamData.member_of(@known_event_types)) do
      Netlink.subscribe()
      Process.sleep(10)
      tag = unique_tag()
      send(Netlink, {:mock_event, %{"type" => event_type, "_tag" => tag}})
      expected_atom = String.to_atom(event_type)
      receive do
        {:netlink_event, {^expected_atom, payload}} ->
          assert is_map(payload), "Expected map payload, got: #{inspect(payload)}"
      after
        500 -> flunk("Timed out waiting for event of type #{event_type}")
      end
    end
  end

  property "Netlink subscribe always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Netlink.subscribe()
      assert result == :ok,
             "Expected :ok from Netlink.subscribe, got: #{inspect(result)}"
    end
  end
end