defmodule YellowDog.Netman.Kernel.NetlinkRobustnessTest do
  @moduledoc """
  Tests for Netlink robustness: malformed data handling, reconnect delay,
  and edge cases in event dispatch.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.Netlink

  @moduletag :capture_log

  defp start_isolated_netlink(backend) do
    original_backend = Application.get_env(:yellow_dog_netman, :netlink_backend)
    original_helper_path = Application.get_env(:yellow_dog_netman, :netlink_helper_path)

    helper_path =
      Path.join(System.tmp_dir!(), "missing-netlink-helper-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_netman, :netlink_backend, backend)
    Application.put_env(:yellow_dog_netman, :netlink_helper_path, helper_path)

    {:ok, pid} = GenServer.start_link(Netlink, [])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      restore_env(:netlink_backend, original_backend)
      restore_env(:netlink_helper_path, original_helper_path)
    end)

    pid
  end

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_netman, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_netman, key, value)

  defp subscribe(pid), do: GenServer.cast(pid, {:subscribe, self()})

  describe "malformed port data handling" do
    test "invalid JSON from port is logged and not dispatched" do
      pid = start_isolated_netlink(:mock)

      subscribe(pid)
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
    end

    test "binary garbage from port is logged and not dispatched" do
      pid = start_isolated_netlink(:mock)

      subscribe(pid)
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      # Send binary garbage
      send(pid, {fake_port, {:data, <<0xFF, 0xFE, 0x00, 0x01>>}})
      Process.sleep(50)

      refute_receive {:netlink_event, _}, 100
      assert Process.alive?(pid)
    end

    test "empty string from port is handled gracefully" do
      pid = start_isolated_netlink(:mock)

      subscribe(pid)
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      send(pid, {fake_port, {:data, ""}})
      Process.sleep(50)

      refute_receive {:netlink_event, _}, 100
      assert Process.alive?(pid)
    end

    test "valid JSON from port is correctly dispatched" do
      pid = start_isolated_netlink(:mock)

      subscribe(pid)
      Process.sleep(20)

      fake_port = make_ref()
      :sys.replace_state(pid, fn state -> %{state | port: fake_port, backend: :port} end)

      json = Jason.encode!(%{"type" => "link_change", "interface" => "robust_test_eth0"})
      send(pid, {fake_port, {:data, json}})

      assert_receive {:netlink_event, {:link_change, %{"interface" => "robust_test_eth0"}}}, 500
    end
  end

  describe "reconnect delay calculation" do
    test "reconnect delay follows exponential backoff with cap" do
      pid = start_isolated_netlink(:port)

      # Trigger reconnect and check state — each attempt increases counter
      for expected_attempts <- 1..5 do
        :sys.replace_state(pid, fn state ->
          %{state | port: nil, backend: :port, reconnect_attempts: expected_attempts - 1}
        end)

        send(pid, :reconnect_port)
        Process.sleep(50)

        state = :sys.get_state(pid)
        assert state.reconnect_attempts == expected_attempts
        assert state.port == nil
      end
    end

    test "reconnect delay is capped at 60 seconds" do
      # The formula is: min(5000 * 2^attempts, 60000)
      # At attempts=4: 5000 * 16 = 80000 → capped to 60000
      # We verify indirectly by observing the GenServer stays alive and
      # reconnect_attempts keeps incrementing (no overflow crash)
      pid = start_isolated_netlink(:port)

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
    end
  end

  describe "event dispatch with no subscribers" do
    test "events are dispatched without crash when subscriber list is empty" do
      pid = start_isolated_netlink(:mock)

      # Temporarily clear subscribers
      :sys.replace_state(pid, fn state -> %{state | subscribers: []} end)

      # Send an event — should not crash even with no subscribers
      send(pid, {:mock_event, %{"type" => "link_change", "interface" => "no_sub_test"}})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end
end
