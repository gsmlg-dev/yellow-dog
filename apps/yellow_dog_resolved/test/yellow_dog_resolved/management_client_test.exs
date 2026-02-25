defmodule YellowDog.Resolved.Management.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.Management.Client

  @ws_config %{
    heartbeat_interval_s: 3600,
    reconnect_base_s: 5,
    reconnect_max_s: 60
  }

  @opts %{
    endpoint: "ws://localhost:9999/ws",
    instance_id: :crypto.strong_rand_bytes(16),
    ws_config: @ws_config
  }

  describe "start_link/1" do
    test "starts the management client" do
      assert {:ok, pid} = start_supervised({Client, @opts})
      assert Process.alive?(pid)
    end

    test "sets connected state on init" do
      start_supervised!({Client, @opts})
      # If we can send a message without crash, it's connected
      Client.send_message(%{"type" => "test"})
      Process.sleep(10)
      assert Process.alive?(Process.whereis(Client))
    end
  end

  describe "send_message/1" do
    setup do
      start_supervised!({Client, @opts})
      :ok
    end

    test "accepts messages when connected" do
      # Should not crash — stub just drops the message
      Client.send_message(%{"type" => "cache_flush"})
      Process.sleep(10)
      assert Process.alive?(Process.whereis(Client))
    end
  end

  describe "handle_info ws_message" do
    setup do
      start_supervised!({Client, @opts})
      :ok
    end

    test "dispatches valid JSON to handler" do
      pid = Process.whereis(Client)
      send(pid, {:ws_message, Jason.encode!(%{"type" => "ping", "id" => "t-1", "data" => %{}})})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles invalid JSON gracefully" do
      pid = Process.whereis(Client)

      capture_log(fn ->
        send(pid, {:ws_message, "not valid json{{"})
        Process.sleep(10)
      end)

      assert Process.alive?(pid)
    end
  end

  describe "handle_info ws_message with crashing handler" do
    setup do
      start_supervised!({Client, @opts})
      :ok
    end

    test "survives handler crash on malformed command data" do
      pid = Process.whereis(Client)

      # Valid JSON but will cause handler issues (missing required "id" field for cache_stats)
      # This tests the safe_handle_command wrapper
      capture_log(fn ->
        send(
          pid,
          {:ws_message, Jason.encode!(%{"type" => "cache_stats"})}
        )

        Process.sleep(20)
      end)

      # Process should survive even if handler crashes
      assert Process.alive?(pid)
    end

    test "survives command that would crash without safe wrapper" do
      pid = Process.whereis(Client)

      # Send a command that requires Cache/Config/Metrics to be running
      # These aren't started in this test context, so handler will crash
      # The safe_handle_command wrapper should catch it
      log =
        capture_log(fn ->
          send(
            pid,
            {:ws_message,
             Jason.encode!(%{
               "type" => "cache_flush",
               "id" => "crash-test",
               "data" => %{"pattern" => nil}
             })}
          )

          Process.sleep(20)
        end)

      assert Process.alive?(pid)
      # Should have logged the crash
      assert log =~ "Command handler crashed"
    end
  end

  describe "heartbeat" do
    test "heartbeat message does not crash the process" do
      # Use very long heartbeat interval so it doesn't fire during test
      start_supervised!({Client, @opts})
      pid = Process.whereis(Client)

      # Manually trigger heartbeat
      send(pid, :heartbeat)
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  describe "catch-all handle_info" do
    test "ignores unexpected messages" do
      start_supervised!({Client, @opts})
      pid = Process.whereis(Client)

      send(pid, :unexpected_message)
      send(pid, {:random, :tuple})
      Process.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      start_supervised!({Client, @opts})

      pid = Process.whereis(Client)
      assert Process.alive?(pid)

      stop_supervised!(Client)

      refute Process.alive?(pid)
    end
  end
end
