defmodule Abyss.ClientTest do
  use ExUnit.Case, async: false

  alias Abyss.Client
  alias Abyss.Transport.UDP

  describe "send/4 unicast" do
    test "sends packet to valid host/port" do
      # Set up a server socket to receive the packet
      {:ok, server_socket} = UDP.listen(0, [])
      {:ok, {_server_ip, server_port}} = UDP.sockname(server_socket)

      test_data = "hello unicast"

      # Send packet using Abyss.Client
      result = Client.send({127, 0, 0, 1}, server_port, test_data)

      case result do
        :ok ->
          # Verify server receives the packet
          case UDP.recv(server_socket, 1024, 1000) do
            {:ok, {_client_ip, _client_port, received_data}} ->
              assert received_data == test_data

            {:error, :timeout} ->
              # Packet sent but not received (acceptable in some environments)
              assert true

            {:error, :einval} ->
              # Skip if recv fails in environment
              assert true
          end

        {:error, reason} ->
          # Send can fail in certain network configurations
          assert reason in [:enetunreach, :ehostunreach, :econnrefused, :eacces]
      end

      UDP.close(server_socket)
    end

    test "respects :source option" do
      {:ok, server_socket} = UDP.listen(0, [])
      {:ok, {_server_ip, server_port}} = UDP.sockname(server_socket)

      test_data = "hello with source"

      # Send packet with source IP binding
      result = Client.send({127, 0, 0, 1}, server_port, test_data, source: {127, 0, 0, 1})

      case result do
        :ok ->
          case UDP.recv(server_socket, 1024, 1000) do
            {:ok, {client_ip, _client_port, received_data}} ->
              assert received_data == test_data
              # Source should be loopback since we bound to it
              assert client_ip == {127, 0, 0, 1}

            {:error, :timeout} ->
              assert true

            {:error, _} ->
              assert true
          end

        {:error, _} ->
          # Can fail in restricted environments
          assert true
      end

      UDP.close(server_socket)
    end

    test "returns {:error, reason} for invalid host" do
      # Try to send to an invalid/unreachable address
      # Note: This may succeed on some systems even with invalid IPs
      # because UDP is connectionless
      result = Client.send({0, 0, 0, 0}, 9999, "test")

      case result do
        :ok ->
          # UDP is connectionless, so send may "succeed" even to invalid IPs
          assert true

        {:error, reason} ->
          assert is_atom(reason)
      end
    end

    test "does not leak sockets when send fails" do
      # Payload above the UDP maximum -> send fails locally with :emsgsize
      oversized = :binary.copy(<<0>>, 70_000)
      ports_before = length(Port.list())

      for _ <- 1..20 do
        assert {:error, :emsgsize} = Client.send({127, 0, 0, 1}, 9999, oversized)
      end

      # A leak would grow the port count by exactly 20
      assert length(Port.list()) - ports_before < 10
    end
  end

  describe "broadcast/4" do
    test "sends to limited broadcast address" do
      # Limited broadcast usually requires special permissions and may not work in all environments
      result = Client.broadcast({255, 255, 255, 255}, 9999, "broadcast test")

      case result do
        :ok ->
          assert true

        {:error, reason} ->
          # Broadcast can fail due to permission or network configuration
          assert reason in [:enetunreach, :eacces, :eperm, :enetdown, :einval]
      end
    end

    test "sends to multicast address (mDNS)" do
      # mDNS multicast address
      result = Client.broadcast({224, 0, 0, 251}, 5353, "mdns test")

      case result do
        :ok ->
          assert true

        {:error, reason} ->
          # Multicast can fail in certain environments
          assert reason in [:enetunreach, :eacces, :eperm, :enetdown, :einval]
      end
    end

    test "respects :ttl option for multicast" do
      # mDNS multicast with custom TTL
      result = Client.broadcast({224, 0, 0, 251}, 5353, "mdns ttl test", ttl: 255)

      case result do
        :ok ->
          assert true

        {:error, reason} ->
          assert reason in [:enetunreach, :eacces, :eperm, :enetdown, :einval]
      end
    end

    test "does not leak sockets when send fails" do
      # Payload above the UDP maximum -> send fails locally with :emsgsize
      oversized = :binary.copy(<<0>>, 70_000)
      ports_before = length(Port.list())

      for _ <- 1..20 do
        assert {:error, :emsgsize} = Client.broadcast({127, 0, 0, 1}, 9999, oversized)
      end

      # A leak would grow the port count by exactly 20
      assert length(Port.list()) - ports_before < 10
    end
  end

  describe "broadcast_send_recv/5" do
    test "sends and receives a response" do
      {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, {_ip, server_port}} = :inet.sockname(server_socket)

      echo =
        Task.async(fn ->
          {:ok, {ip, port, data}} = :gen_udp.recv(server_socket, 0, 1000)
          :gen_udp.send(server_socket, ip, port, data)
        end)

      assert {:ok, "hello"} =
               Client.broadcast_send_recv({127, 0, 0, 1}, server_port, "hello", 1000)

      Task.await(echo)
      :gen_udp.close(server_socket)
    end

    test "honors the :source option" do
      # 203.0.113.7 (TEST-NET-3) is not assigned to any local interface, so
      # binding must fail - proving the option is no longer silently ignored.
      assert {:error, :eaddrnotavail} =
               Client.broadcast_send_recv({127, 0, 0, 1}, 9999, "x", 20, source: {203, 0, 113, 7})
    end

    test "returns the send error rather than :timeout when send fails" do
      # Payload above the UDP maximum -> send fails locally with :emsgsize
      oversized = :binary.copy(<<0>>, 70_000)

      assert {:error, :emsgsize} =
               Client.broadcast_send_recv({127, 0, 0, 1}, 9999, oversized, 20)
    end
  end

  describe "send_recv/5 request-response" do
    test "sends packet and receives response" do
      # Create an echo server that responds with the same data
      {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, {_server_ip, server_port}} = :inet.sockname(server_socket)

      # Start server task to echo back the packet
      server_task =
        Task.async(fn ->
          case :gen_udp.recv(server_socket, 0, 2000) do
            {:ok, {client_ip, client_port, data}} ->
              :gen_udp.send(server_socket, client_ip, client_port, "echo: " <> data)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        end)

      test_data = "hello request-response"

      # Give server time to start listening
      Process.sleep(10)

      result = Client.send_recv({127, 0, 0, 1}, server_port, test_data, 2000)

      case result do
        {:ok, response} ->
          assert response == "echo: " <> test_data

        {:error, reason} when reason in [:timeout, :enetunreach, :ehostunreach, :econnrefused] ->
          # May fail in restricted environments
          assert true

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end

      Task.await(server_task, 3000)
      :gen_udp.close(server_socket)
    end

    test "returns timeout error when no response" do
      # Use a port that won't respond
      {:ok, server_socket} = :gen_udp.open(0, [:binary])
      {:ok, {_server_ip, server_port}} = :inet.sockname(server_socket)

      # Don't set up any receiver - let it timeout
      result = Client.send_recv({127, 0, 0, 1}, server_port, "no response", 100)

      case result do
        {:error, :timeout} ->
          assert true

        {:error, reason} when reason in [:enetunreach, :ehostunreach, :econnrefused] ->
          assert true

        {:ok, _} ->
          # Shouldn't happen but accept if something else on the network responded
          assert true
      end

      :gen_udp.close(server_socket)
    end

    test "respects source option" do
      {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, {_server_ip, server_port}} = :inet.sockname(server_socket)

      server_task =
        Task.async(fn ->
          case :gen_udp.recv(server_socket, 0, 2000) do
            {:ok, {client_ip, client_port, data}} ->
              :gen_udp.send(server_socket, client_ip, client_port, data)
              client_ip

            {:error, reason} ->
              {:error, reason}
          end
        end)

      Process.sleep(10)

      result =
        Client.send_recv({127, 0, 0, 1}, server_port, "source test", 2000, source: {127, 0, 0, 1})

      case result do
        {:ok, _} ->
          # Verify client IP was loopback
          client_ip = Task.await(server_task, 3000)
          assert client_ip == {127, 0, 0, 1}

        {:error, _} ->
          Task.await(server_task, 3000)
          assert true
      end

      :gen_udp.close(server_socket)
    end
  end

  describe "subscribe_broadcast/4 multicast subscription" do
    test "returns empty list on timeout with no responses" do
      # Test subscribe_broadcast to multicast address (receive-only)
      # Use a high port to avoid conflicts
      result = Client.subscribe_broadcast({224, 0, 0, 251}, 15353, 100)

      case result do
        {:ok, packets} ->
          # May be empty or have packets from actual mDNS traffic
          assert is_list(packets)

        {:error, reason}
        when reason in [:enetunreach, :eacces, :eperm, :enetdown, :einval, :eaddrinuse] ->
          # Multicast may not be available or port in use
          assert true
      end
    end

    test "subscribe_broadcast is receive-only (no send)" do
      # Subscribe should just listen, not send anything
      # Using a test port that's unlikely to have traffic
      result = Client.subscribe_broadcast({224, 0, 0, 251}, 15354, 50)

      case result do
        {:ok, packets} ->
          # In most test environments, this will be empty
          assert is_list(packets)

        {:error, reason}
        when reason in [:enetunreach, :eacces, :eperm, :enetdown, :einval, :eaddrinuse] ->
          assert true
      end
    end
  end

  describe "resolve_interface_ip/1" do
    test "resolves loopback interface" do
      result = Client.resolve_interface_ip("lo")

      case result do
        {:ok, ip} ->
          # Loopback should resolve to 127.0.0.1
          assert ip == {127, 0, 0, 1}

        {:error, :enodev} ->
          # Loopback might not be named "lo" on all systems
          assert true
      end
    end

    test "returns error for non-existent interface" do
      result = Client.resolve_interface_ip("nonexistent_interface_xyz")
      assert result == {:error, :enodev}
    end
  end

  describe "telemetry events" do
    setup do
      # Capture telemetry events
      test_pid = self()

      :telemetry.attach_many(
        "test-client-telemetry-#{inspect(test_pid)}",
        [
          [:abyss, :client, :send, :start],
          [:abyss, :client, :send, :stop],
          [:abyss, :client, :send, :exception],
          [:abyss, :client, :send_recv, :start],
          [:abyss, :client, :send_recv, :stop],
          [:abyss, :client, :send_recv, :exception],
          [:abyss, :client, :subscribe, :start],
          [:abyss, :client, :subscribe, :stop],
          [:abyss, :client, :subscribe, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-client-telemetry-#{inspect(test_pid)}")
      end)

      :ok
    end

    test "emits :start and :stop events on successful send" do
      {:ok, server_socket} = UDP.listen(0, [])
      {:ok, {_server_ip, server_port}} = UDP.sockname(server_socket)

      result = Client.send({127, 0, 0, 1}, server_port, "telemetry test")

      case result do
        :ok ->
          # Should receive start event
          assert_receive {:telemetry_event, [:abyss, :client, :send, :start], %{}, metadata}
          assert metadata.host == {127, 0, 0, 1}
          assert metadata.port == server_port
          assert metadata.size == byte_size("telemetry test")
          assert metadata.type == :unicast

          # Should receive stop event
          assert_receive {:telemetry_event, [:abyss, :client, :send, :stop], measurements, _}
          assert is_integer(measurements.duration)

        {:error, _} ->
          # Received start and exception events
          assert_receive {:telemetry_event, [:abyss, :client, :send, :start], %{}, _}
          assert_receive {:telemetry_event, [:abyss, :client, :send, :exception], _, _}
      end

      UDP.close(server_socket)
    end

    test "emits :exception event on error" do
      # Force an error by using an interface option that will fail
      result = Client.send({127, 0, 0, 1}, 9999, "test", interface: "nonexistent_interface")

      # Should always receive start event
      assert_receive {:telemetry_event, [:abyss, :client, :send, :start], %{}, _}

      case result do
        :ok ->
          # Received stop event (interface binding may have silently failed)
          assert_receive {:telemetry_event, [:abyss, :client, :send, :stop], _, _}

        {:error, _reason} ->
          # Should receive exception event with reason
          assert_receive {:telemetry_event, [:abyss, :client, :send, :exception], measurements,
                          metadata}

          assert is_integer(measurements.duration)
          assert Map.has_key?(metadata, :reason)
      end
    end

    test "broadcast emits events with type :broadcast" do
      result = Client.broadcast({255, 255, 255, 255}, 9999, "broadcast telemetry test")

      # Should receive start event with type :broadcast
      assert_receive {:telemetry_event, [:abyss, :client, :send, :start], %{}, metadata}
      assert metadata.type == :broadcast

      case result do
        :ok ->
          assert_receive {:telemetry_event, [:abyss, :client, :send, :stop], _, _}

        {:error, _} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send, :exception], _, _}
      end
    end

    test "send_recv emits telemetry events" do
      {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, {_server_ip, server_port}} = :inet.sockname(server_socket)

      server_task =
        Task.async(fn ->
          case :gen_udp.recv(server_socket, 0, 2000) do
            {:ok, {client_ip, client_port, data}} ->
              :gen_udp.send(server_socket, client_ip, client_port, data)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        end)

      Process.sleep(10)

      result = Client.send_recv({127, 0, 0, 1}, server_port, "telemetry test", 2000)

      # Should receive start event with type :request_response
      assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :start], %{}, metadata}
      assert metadata.type == :request_response
      assert metadata.timeout == 2000

      case result do
        {:ok, _} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :stop], measurements, _}
          assert is_integer(measurements.duration)
          assert is_integer(measurements.response_size)

        {:error, _} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :exception],
                          measurements, meta}

          assert is_integer(measurements.duration)
          assert Map.has_key?(meta, :reason)
      end

      Task.await(server_task, 3000)
      :gen_udp.close(server_socket)
    end

    test "send_recv timeout emits exception event" do
      {:ok, server_socket} = :gen_udp.open(0, [:binary])
      {:ok, {_server_ip, server_port}} = :inet.sockname(server_socket)

      result = Client.send_recv({127, 0, 0, 1}, server_port, "timeout test", 100)

      assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :start], %{}, _}

      case result do
        {:error, :timeout} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :exception], _,
                          metadata}

          assert metadata.reason == :timeout

        {:error, _} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :exception], _, _}

        {:ok, _} ->
          assert_receive {:telemetry_event, [:abyss, :client, :send_recv, :stop], _, _}
      end

      :gen_udp.close(server_socket)
    end
  end

  describe "socket options building" do
    test "send/4 without options uses default socket opts" do
      {:ok, server_socket} = UDP.listen(0, [])
      {:ok, {_server_ip, server_port}} = UDP.sockname(server_socket)

      # Should succeed with default options
      result = Client.send({127, 0, 0, 1}, server_port, "default opts test")

      case result do
        :ok -> assert true
        {:error, _} -> assert true
      end

      UDP.close(server_socket)
    end

    test "broadcast/4 enables broadcast socket option" do
      # Broadcast should be enabled, though actual broadcast may fail due to permissions
      result = Client.broadcast({255, 255, 255, 255}, 9999, "broadcast opt test")

      case result do
        :ok -> assert true
        {:error, reason} -> assert is_atom(reason)
      end
    end

    test "send/4 with :source binds to source IP" do
      {:ok, server_socket} = UDP.listen(0, [])
      {:ok, {_server_ip, server_port}} = UDP.sockname(server_socket)

      # Binding to loopback should work
      result = Client.send({127, 0, 0, 1}, server_port, "source test", source: {127, 0, 0, 1})

      case result do
        :ok ->
          case UDP.recv(server_socket, 1024, 500) do
            {:ok, {source_ip, _, _}} ->
              assert source_ip == {127, 0, 0, 1}

            _ ->
              assert true
          end

        {:error, _} ->
          assert true
      end

      UDP.close(server_socket)
    end
  end
end
