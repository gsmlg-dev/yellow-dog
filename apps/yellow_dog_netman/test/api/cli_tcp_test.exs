defmodule YellowDog.Netman.API.CLITcpTest do
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI

  defp connect_to_cli do
    socket_path = :sys.get_state(CLI).socket_path

    :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
      :binary,
      packet: :line,
      active: false
    ])
  end

  # Read events until a keepalive is received or attempts are exhausted.
  # Other tests may emit telemetry events that stream through the monitor
  # connection before the keepalive timeout fires.
  defp await_keepalive(socket, attempts \\ 20) do
    assert attempts > 0, "keepalive not received within expected attempt window"

    case :gen_tcp.recv(socket, 0, 500) do
      {:ok, line} ->
        event = Jason.decode!(String.trim(line))

        if event["event"] == "keepalive" do
          :ok
        else
          await_keepalive(socket, attempts - 1)
        end

      {:error, reason} ->
        flunk("socket error while waiting for keepalive: #{inspect(reason)}")
    end
  end

  describe "Unix socket accept loop" do
    test "CLI accepts a JSON command and returns a response" do
      {:ok, socket} = connect_to_cli()

      :gen_tcp.send(socket, Jason.encode!(%{"method" => "status"}) <> "\n")

      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert Map.has_key?(response, "result")
    end

    test "CLI returns error for invalid JSON" do
      {:ok, socket} = connect_to_cli()

      :gen_tcp.send(socket, "not valid json\n")

      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => "invalid JSON"} = response
    end

    test "CLI handles multiple sequential connections" do
      for _ <- 1..3 do
        {:ok, socket} = connect_to_cli()

        # Use "status" which returns a small fixed-size response regardless of system state
        :gen_tcp.send(socket, Jason.encode!(%{"method" => "status"}) <> "\n")
        {:ok, response_line} = :gen_tcp.recv(socket, 0, 5000)
        :gen_tcp.close(socket)

        {:ok, response} = Jason.decode(response_line)
        assert %{"result" => %{"running" => true}} = response
      end
    end
  end

  describe "monitor over Unix socket" do
    @tag :capture_log
    test "monitor command streams events until client disconnects" do
      {:ok, socket} = connect_to_cli()

      :gen_tcp.send(socket, Jason.encode!(%{"method" => "monitor"}) <> "\n")

      # Should receive monitor_started
      {:ok, started_line} = :gen_tcp.recv(socket, 0, 2000)
      assert %{"event" => "monitor_started"} = Jason.decode!(String.trim(started_line))

      # Trigger a telemetry event via MockNetlink
      iface = "tcp_mon_#{:rand.uniform(100_000)}"
      YellowDog.Netman.Test.MockNetlink.link_up(iface)
      Process.sleep(100)

      # Read the streamed event
      {:ok, event_line} = :gen_tcp.recv(socket, 0, 2000)
      event = Jason.decode!(String.trim(event_line))
      assert event["event"] == "yellow_dog.netman.kernel.link_change"
      assert is_map(event["metadata"])
      assert is_map(event["measurements"])

      # Disconnect client — monitor loop should exit cleanly
      :gen_tcp.close(socket)

      YellowDog.Netman.Test.MockNetlink.link_removed(iface)
    end
  end

  describe "monitor keepalive" do
    setup do
      Application.put_env(:yellow_dog_netman, :cli_monitor_keepalive_ms, 50)
      on_exit(fn -> Application.delete_env(:yellow_dog_netman, :cli_monitor_keepalive_ms) end)
      :ok
    end

    test "keepalive is sent when no events arrive within the timeout" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, Jason.encode!(%{"method" => "monitor"}) <> "\n")

      {:ok, started_line} = :gen_tcp.recv(socket, 0, 2000)
      assert %{"event" => "monitor_started"} = Jason.decode!(String.trim(started_line))

      # Drain any concurrent telemetry events until the keepalive arrives.
      # Other tests running in parallel may emit link/address events that
      # stream to this monitor client before the 50ms keepalive fires.
      assert :ok = await_keepalive(socket)

      :gen_tcp.close(socket)
    end

    test "keepalive error path exits monitor loop when socket is closed" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, Jason.encode!(%{"method" => "monitor"}) <> "\n")

      {:ok, started_line} = :gen_tcp.recv(socket, 0, 2000)
      assert %{"event" => "monitor_started"} = Jason.decode!(String.trim(started_line))

      # Close socket from client side; keepalive fires, send fails → {:error, _} branch
      :gen_tcp.close(socket)

      # Give the server task time to process the closed socket + keepalive
      Process.sleep(200)

      # Server CLI GenServer should still be alive
      assert Process.alive?(Process.whereis(CLI))
    end
  end

  describe "edge cases" do
    test "client that disconnects before sending data is handled" do
      {:ok, socket} = connect_to_cli()

      # Close immediately without sending anything — exercises recv error path
      :gen_tcp.close(socket)
      Process.sleep(50)

      # Server should still be alive and accepting new connections
      {:ok, socket2} = connect_to_cli()

      :gen_tcp.send(socket2, Jason.encode!(%{"method" => "status"}) <> "\n")
      {:ok, response} = :gen_tcp.recv(socket2, 0, 2000)
      :gen_tcp.close(socket2)

      assert {:ok, %{"result" => _}} = Jason.decode(response)
    end

    test "monitor with tuple values in telemetry metadata" do
      {:ok, socket} = connect_to_cli()

      :gen_tcp.send(socket, Jason.encode!(%{"method" => "monitor"}) <> "\n")
      {:ok, _started} = :gen_tcp.recv(socket, 0, 2000)

      # Emit a telemetry event with a tuple in metadata (exercises stringify_value/1 tuple clause)
      :telemetry.execute(
        [:yellow_dog, :netman, :kernel, :link_change],
        %{count: 1},
        %{interface: "test0", address: {192, 168, 1, 1}, action: :up}
      )

      {:ok, event_line} = :gen_tcp.recv(socket, 0, 2000)
      event = Jason.decode!(String.trim(event_line))
      # Tuple should be serialized via inspect
      assert is_binary(event["metadata"]["address"])
      assert event["metadata"]["address"] =~ "192"

      :gen_tcp.close(socket)
    end

    @tag :capture_log
    test "client handler rescue clause fires and CLI survives when monitor crashes" do
      {:ok, socket} = connect_to_cli()

      :gen_tcp.send(socket, Jason.encode!(%{"method" => "monitor"}) <> "\n")
      {:ok, _started} = :gen_tcp.recv(socket, 0, 2000)

      # Functions are not JSON-serializable; stringify_value/1 has no clause for
      # them so the value passes through as-is and Jason.encode! raises
      # Protocol.UndefinedError inside monitor_loop. The Task's rescue clause
      # (L93-95) catches this, logs a warning, and closes the client socket.
      :telemetry.execute(
        [:yellow_dog, :netman, :kernel, :link_change],
        %{count: 1},
        %{action: :up, bad_value: fn -> :crash end}
      )

      # Give the monitor task time to process the event and crash
      Process.sleep(200)

      # CLI GenServer must still be alive despite the monitor task crash
      assert Process.alive?(Process.whereis(CLI))

      # CLI must still serve new connections after the crash
      {:ok, socket2} = connect_to_cli()
      :gen_tcp.send(socket2, Jason.encode!(%{"method" => "status"}) <> "\n")
      {:ok, response} = :gen_tcp.recv(socket2, 0, 2000)
      :gen_tcp.close(socket2)
      assert {:ok, %{"result" => _}} = Jason.decode(response)
    end
  end
end
