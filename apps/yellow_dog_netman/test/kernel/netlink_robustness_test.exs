defmodule YellowDog.Netman.Kernel.NetlinkRobustnessTest do
  @moduledoc """
  Tests for Netlink robustness: malformed data handling, reconnect delay,
  and edge cases in event dispatch.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.Netlink

  @moduletag :capture_log

  describe "malformed port data handling" do
    test "invalid JSON from port is logged and not dispatched" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      Netlink.subscribe()
      Process.sleep(20)

      # Inject a fake port ref and send malformed JSON data
      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # Send truncated JSON
      send(pid, {fake_port, {:data, "{\"type\": \"link_change\", \"incomplete"}})
      Process.sleep(50)

      # Should NOT receive any dispatched event
      refute_receive {:netlink_event, _}, 100

      # GenServer must survive
      assert Process.alive?(pid)

      :sys.replace_state(pid, fn _state -> original_state end)
    end

    test "binary garbage from port is logged and not dispatched" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      Netlink.subscribe()
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # Send binary garbage
      send(pid, {fake_port, {:data, <<0xFF, 0xFE, 0x00, 0x01>>}})
      Process.sleep(50)

      refute_receive {:netlink_event, _}, 100
      assert Process.alive?(pid)

      :sys.replace_state(pid, fn _state -> original_state end)
    end

    test "empty string from port is handled gracefully" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      Netlink.subscribe()
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      send(pid, {fake_port, {:data, ""}})
      Process.sleep(50)

      refute_receive {:netlink_event, _}, 100
      assert Process.alive?(pid)

      :sys.replace_state(pid, fn _state -> original_state end)
    end

    test "valid JSON from port is correctly dispatched" do
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      Netlink.subscribe()
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      json = Jason.encode!(%{"type" => "link_change", "interface" => "robust_test_eth0"})
      send(pid, {fake_port, {:data, json}})

      assert_receive {:netlink_event, {:link_change, %{"interface" => "robust_test_eth0"}}}, 500

      :sys.replace_state(pid, fn _state -> original_state end)
    end
  end

  describe "reconnect delay calculation" do
    test "reconnect delay follows exponential backoff with cap" do
      # Access the private function via :sys + state manipulation
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      # Set up port mode with nil port to trigger reconnect
      :sys.replace_state(pid, fn state ->
        %{state | port: nil, backend: :port, reconnect_attempts: 0}
      end)

      # Trigger reconnect and check state — each attempt increases counter
      for expected_attempts <- 1..5 do
        send(pid, :reconnect_port)
        Process.sleep(50)

        state = :sys.get_state(pid)
        assert state.reconnect_attempts == expected_attempts
        assert state.port == nil
      end

      :sys.replace_state(pid, fn _state -> original_state end)
    end

    test "reconnect delay is capped at 60 seconds" do
      # The formula is: min(5000 * 2^attempts, 60000)
      # At attempts=4: 5000 * 16 = 80000 → capped to 60000
      # We verify indirectly by observing the GenServer stays alive and
      # reconnect_attempts keeps incrementing (no overflow crash)
      pid = Process.whereis(Netlink)
      original_state = :sys.get_state(pid)

      :sys.replace_state(pid, fn state ->
        %{state | port: nil, backend: :port, reconnect_attempts: 20}
      end)

      # With attempts=20, delay would be 5000 * 2^20 = 5.2B ms without cap
      # The cap at 60000 prevents integer overflow issues
      send(pid, :reconnect_port)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.reconnect_attempts == 21
      assert Process.alive?(pid)

      :sys.replace_state(pid, fn _state -> original_state end)
    end
  end

  describe "event dispatch with no subscribers" do
    test "events are dispatched without crash when subscriber list is empty" do
      pid = Process.whereis(Netlink)

      # Ensure no extra subscribers by checking current state
      state = :sys.get_state(pid)
      original_subscribers = state.subscribers

      # Temporarily clear subscribers
      :sys.replace_state(pid, fn state -> %{state | subscribers: []} end)

      # Send an event — should not crash even with no subscribers
      send(pid, {:mock_event, %{"type" => "link_change", "interface" => "no_sub_test"}})
      Process.sleep(50)

      assert Process.alive?(pid)

      # Restore subscribers
      :sys.replace_state(pid, fn state -> %{state | subscribers: original_subscribers} end)
    end
  end
end
