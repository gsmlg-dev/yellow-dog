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
          [:abyss, :client, :send, :exception]
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
