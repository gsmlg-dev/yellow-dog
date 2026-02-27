defmodule YellowDog.Netman.API.CLITcpTest do
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI

  defp get_cli_port do
    state = :sys.get_state(CLI)
    {:ok, port} = :inet.port(state.listen_socket)
    port
  end

  describe "TCP accept loop" do
    test "CLI accepts a JSON command and returns a response" do
      port = get_cli_port()

      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      :gen_tcp.send(socket, Jason.encode!(%{"method" => "status"}) <> "\n")

      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert Map.has_key?(response, "result")
    end

    test "CLI returns error for invalid JSON" do
      port = get_cli_port()

      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      :gen_tcp.send(socket, "not valid json\n")

      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => "invalid JSON"} = response
    end

    test "CLI handles multiple sequential connections" do
      port = get_cli_port()

      for _ <- 1..3 do
        {:ok, socket} =
          :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

        # Use "status" which returns a small fixed-size response regardless of system state
        :gen_tcp.send(socket, Jason.encode!(%{"method" => "status"}) <> "\n")
        {:ok, response_line} = :gen_tcp.recv(socket, 0, 5000)
        :gen_tcp.close(socket)

        {:ok, response} = Jason.decode(response_line)
        assert %{"result" => %{"running" => true}} = response
      end
    end
  end

  describe "monitor over TCP" do
    @tag :capture_log
    test "monitor command streams events until client disconnects" do
      port = get_cli_port()

      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

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
end
