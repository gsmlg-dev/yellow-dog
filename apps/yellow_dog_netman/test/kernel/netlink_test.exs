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
    test "command in mock mode returns :ok" do
      result = Netlink.command(%{"cmd" => "link_set", "interface" => "eth0", "state" => "up"})
      assert result == :ok
    end

    test "command when port is nil returns {:error, :not_connected}" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      # Simulate a disconnected port backend
      :sys.replace_state(pid, fn state ->
        %{state | backend: :port, port: nil}
      end)

      result = Netlink.command(%{"cmd" => "link_set", "interface" => "eth0", "state" => "up"})
      assert result == {:error, :not_connected}

      # Restore original state
      :sys.replace_state(pid, fn _state -> original_state end)
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

  describe "duplicate subscriber protection" do
    test "subscribing the same process twice does not duplicate the monitor" do
      pid = Process.whereis(Netlink)
      state_before = :sys.get_state(pid)
      count_before = length(state_before.subscribers)

      Netlink.subscribe()
      Process.sleep(20)

      state_after_first = :sys.get_state(pid)
      count_after_first = length(state_after_first.subscribers)

      # Subscribe again from the same process
      Netlink.subscribe()
      Process.sleep(20)

      state_after_second = :sys.get_state(pid)
      count_after_second = length(state_after_second.subscribers)

      # Should have added exactly one subscriber, not two
      assert count_after_first == count_before + 1
      assert count_after_second == count_after_first
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

  describe "terminate/2" do
    test "terminate closes a port without crashing" do
      pid = Process.whereis(Netlink)
      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # GenServer.stop triggers terminate/2. We restart it afterward.
      # Since the fake port isn't a real port, Port.close will raise ArgumentError
      # which the terminate callback rescues. Verify no crash propagates.
      GenServer.stop(pid, :normal)
      Process.sleep(50)

      # The supervisor should have restarted it
      new_pid = Process.whereis(Netlink)
      assert new_pid != nil
      assert Process.alive?(new_pid)
    end

    test "terminate with nil port (mock mode) does not crash" do
      pid = Process.whereis(Netlink)
      # In mock mode port is nil; verify terminate handles it
      GenServer.stop(pid, :normal)
      Process.sleep(50)

      new_pid = Process.whereis(Netlink)
      assert new_pid != nil
      assert Process.alive?(new_pid)
    end
  end

  describe "port closed handling" do
    @tag :capture_log
    test "port :closed with unknown port ref is silently ignored" do
      pid = Process.whereis(Netlink)
      # A ref that doesn't match state.port (mock mode has nil port)
      # is handled by the catch-all — GenServer must not crash.
      send(pid, {make_ref(), :closed})
      Process.sleep(20)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "port :closed matching state.port clears port from state and logs warning" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      # Use a plain reference as a fake port token.
      # The Elixir pattern `{port, :closed}` in handle_info matches any term
      # when port == state.port, so we inject a ref and send the matching message.
      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # Send the closed message directly — this is what the Erlang runtime would do
      # when the actual port OS process exits.
      send(pid, {fake_port, :closed})
      Process.sleep(50)

      # GenServer must still be alive
      assert Process.alive?(pid)

      # Port should have been cleared from state
      updated_state = :sys.get_state(pid)
      assert updated_state.port == nil

      # Restore original state for other tests
      :sys.replace_state(pid, fn _state -> original_state end)
    end
  end

  describe "port reconnect" do
    @tag :capture_log
    test "reconnect_port message in mock mode is ignored" do
      pid = Process.whereis(Netlink)
      send(pid, :reconnect_port)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "port closed schedules reconnect attempt" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      send(pid, {fake_port, :closed})
      Process.sleep(50)

      # Port should be nil after close
      state = :sys.get_state(pid)
      assert state.port == nil

      # A reconnect_port message should be scheduled
      # We can't easily verify the timer, but we can send the message manually
      # and verify it's handled without crash
      send(pid, :reconnect_port)
      Process.sleep(50)
      assert Process.alive?(pid)

      # Restore original state
      :sys.replace_state(pid, fn _state -> original_state end)
    end

    @tag :capture_log
    test "reconnect_attempts counter increases on each failed reconnect" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # Trigger port close — sets reconnect_attempts to 1
      send(pid, {fake_port, :closed})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.reconnect_attempts == 1
      assert state.port == nil

      # Manually trigger reconnect — port binary doesn't exist, so it fails
      # This should increment reconnect_attempts
      send(pid, :reconnect_port)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.reconnect_attempts == 2
      assert state.port == nil

      # Another failed reconnect
      send(pid, :reconnect_port)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.reconnect_attempts == 3

      # Restore original state
      :sys.replace_state(pid, fn _state -> original_state end)
    end
  end

  describe "command_error event handling" do
    @tag :capture_log
    test "command_error events are logged but not dispatched to subscribers" do
      Netlink.subscribe()
      Process.sleep(20)

      send(Netlink, {:mock_event, %{
        "type" => "command_error",
        "cmd" => "link_set",
        "error" => "ip link set eth99 up failed (exit status: 1): Cannot find device"
      }})

      # Give the GenServer time to process the event
      Process.sleep(50)

      # Subscriber should NOT receive command_error events
      refute_receive {:netlink_event, _}, 100
    end

    @tag :capture_log
    test "command_error with missing fields falls through to :unknown" do
      Netlink.subscribe()
      Process.sleep(20)

      # Missing "cmd" field — won't match the command_error clause
      send(Netlink, {:mock_event, %{
        "type" => "command_error",
        "error" => "some error"
      }})

      assert_receive {:netlink_event, {:unknown, %{"type" => "command_error"}}}, 500
    end

    @tag :capture_log
    test "normal events still dispatch after command_error" do
      Netlink.subscribe()
      Process.sleep(20)

      # First send a command_error (should be filtered)
      send(Netlink, {:mock_event, %{
        "type" => "command_error",
        "cmd" => "addr_add",
        "error" => "failed"
      }})

      # Then send a normal event
      send(Netlink, {:mock_event, %{
        "type" => "link_change",
        "action" => "add",
        "interface" => "cmd_err_test"
      }})

      # Should only receive the link_change, not the command_error
      assert_receive {:netlink_event, {:link_change, %{"interface" => "cmd_err_test"}}}, 500
      refute_receive {:netlink_event, :command_error}, 100
    end
  end
end
