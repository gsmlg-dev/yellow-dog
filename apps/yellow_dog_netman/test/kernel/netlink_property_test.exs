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
end
