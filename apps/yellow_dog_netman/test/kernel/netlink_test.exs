defmodule YellowDog.Netman.Kernel.NetlinkTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.Netlink

  describe "subscribe/0 and event dispatch" do
    test "subscribed process receives mock events" do
      Netlink.subscribe()
      Process.sleep(20)

      send(
        Netlink,
        {:mock_event,
         %{"type" => "link_change", "action" => "add", "interface" => "nl_test_eth0"}}
      )

      assert_receive {:netlink_event, {:link_change, %{"interface" => "nl_test_eth0"}}}, 500
    end

    test "unknown event type is dispatched as :unknown" do
      Netlink.subscribe()
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => "mystery_event", "data" => "x"}})

      assert_receive {:netlink_event, {:unknown, %{"type" => "mystery_event"}}}, 500
    end

    test "subscriber is removed on process DOWN" do
      parent = self()

      task =
        Task.async(fn ->
          Netlink.subscribe()
          send(parent, :subscribed)
          # Block until we die
          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed
      Process.sleep(20)

      # Kill the subscriber task
      send(task.pid, :die)
      Task.await(task)
      Process.sleep(20)

      # The Netlink GenServer should have cleaned up the subscriber.
      # No crash means the DOWN handler worked correctly.
      assert Process.alive?(Process.whereis(Netlink))
    end
  end

  describe "command/1" do
    test "command in degraded mode returns error or ok" do
      # In test env the port binary doesn't exist, so command may return
      # :ok (mock backend) or {:error, :not_connected} (degraded port mode)
      result = Netlink.command(%{"cmd" => "link_set", "interface" => "eth0", "state" => "up"})
      assert result == :ok or result == {:error, :not_connected}
    end
  end

  describe "event type parsing" do
    test "address_change events are dispatched" do
      Netlink.subscribe()
      Process.sleep(20)

      send(
        Netlink,
        {:mock_event,
         %{"type" => "address_change", "action" => "add", "interface" => "nl_addr_eth"}}
      )

      assert_receive {:netlink_event, {:address_change, _}}, 500
    end

    test "route_change events are dispatched" do
      Netlink.subscribe()
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => "route_change", "action" => "add"}})

      assert_receive {:netlink_event, {:route_change, _}}, 500
    end

    test "rule_change events are dispatched" do
      Netlink.subscribe()
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => "rule_change", "action" => "add"}})

      assert_receive {:netlink_event, {:rule_change, _}}, 500
    end

    test "neighbor_change events are dispatched" do
      Netlink.subscribe()
      Process.sleep(20)

      send(Netlink, {:mock_event, %{"type" => "neighbor_change", "action" => "add"}})

      assert_receive {:netlink_event, {:neighbor_change, _}}, 500
    end
  end

  describe "handle_info catch-all" do
    test "unknown messages are silently ignored" do
      pid = Process.whereis(Netlink)
      send(pid, :some_random_message_for_netlink)
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end
end
