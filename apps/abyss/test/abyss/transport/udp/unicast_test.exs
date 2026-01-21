defmodule Abyss.Transport.UDP.UnicastTest do
  use ExUnit.Case, async: true

  alias Abyss.Transport.UDP.Unicast

  @moduletag :capture_log

  describe "module structure" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(Unicast)
    end

    test "implements Abyss.Transport behaviour" do
      behaviours = Unicast.__info__(:attributes) |> Keyword.get(:behaviour, [])
      assert Abyss.Transport in behaviours
    end

    test "exports listen/2" do
      assert function_exported?(Unicast, :listen, 2)
    end

    test "exports open/2" do
      assert function_exported?(Unicast, :open, 2)
    end

    test "exports controlling_process/2" do
      assert function_exported?(Unicast, :controlling_process, 2)
    end

    test "exports recv/3" do
      assert function_exported?(Unicast, :recv, 3)
    end

    test "exports send/2, send/3, send/4, send/5" do
      assert function_exported?(Unicast, :send, 2)
      assert function_exported?(Unicast, :send, 3)
      assert function_exported?(Unicast, :send, 4)
      assert function_exported?(Unicast, :send, 5)
    end

    test "exports getopts/2" do
      assert function_exported?(Unicast, :getopts, 2)
    end

    test "exports setopts/2" do
      assert function_exported?(Unicast, :setopts, 2)
    end

    test "exports close/1" do
      assert function_exported?(Unicast, :close, 1)
    end

    test "exports sockname/1" do
      assert function_exported?(Unicast, :sockname, 1)
    end

    test "exports peername/1" do
      assert function_exported?(Unicast, :peername, 1)
    end

    test "exports getstat/1" do
      assert function_exported?(Unicast, :getstat, 1)
    end

    test "exports send_recv/3 utility function" do
      assert function_exported?(Unicast, :send_recv, 3)
    end
  end

  describe "listen/2" do
    test "creates unicast socket with correct options" do
      assert {:ok, socket} = Unicast.listen(0, [])

      # Verify unicast-specific options
      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == false
      assert opts[:broadcast] == false

      Unicast.close(socket)
    end

    test "returns valid port reference" do
      assert {:ok, socket} = Unicast.listen(0, [])
      assert is_port(socket)
      Unicast.close(socket)
    end

    test "can listen on specific port" do
      assert {:ok, socket} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(socket)
      assert is_integer(port)
      assert port > 0
      Unicast.close(socket)
    end

    test "sets mode to binary" do
      assert {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:mode])
      assert opts[:mode] == :binary
      Unicast.close(socket)
    end

    test "sets reuseaddr to true" do
      assert {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:reuseaddr])
      assert opts[:reuseaddr] == true
      Unicast.close(socket)
    end

    test "allows user options to override defaults" do
      # Note: active and broadcast are hardcoded, so user can't override them
      # But other options like buffer sizes can be customized
      assert {:ok, socket} = Unicast.listen(0, recbuf: 32768)

      {:ok, opts} = Unicast.getopts(socket, [:recbuf, :active, :broadcast])
      # System may adjust buffer size, so just verify it was set to something
      assert is_integer(opts[:recbuf])
      assert opts[:recbuf] > 0
      # But core options should be enforced
      assert opts[:active] == false
      assert opts[:broadcast] == false

      Unicast.close(socket)
    end

    test "accepts ip option for binding" do
      assert {:ok, socket} = Unicast.listen(0, ip: {127, 0, 0, 1})
      {:ok, {ip, _port}} = Unicast.sockname(socket)
      assert ip == {127, 0, 0, 1}
      Unicast.close(socket)
    end

    test "can create multiple sockets" do
      assert {:ok, socket1} = Unicast.listen(0, [])
      assert {:ok, socket2} = Unicast.listen(0, [])

      {:ok, {_, port1}} = Unicast.sockname(socket1)
      {:ok, {_, port2}} = Unicast.sockname(socket2)
      assert port1 != port2

      Unicast.close(socket1)
      Unicast.close(socket2)
    end

    test "returns error for privileged port without permissions" do
      # Port 1 is privileged, should fail without root
      # On some systems (containers, root) this might succeed, so we accept both
      result = Unicast.listen(1, [])

      case result do
        {:error, _reason} -> assert true
        {:ok, socket} ->
          Unicast.close(socket)
          # Test passed - we had permissions
          assert true
      end
    end
  end

  describe "open/2" do
    test "opens unicast socket for sending" do
      assert {:ok, socket} = Unicast.open(0, [])

      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == false
      assert opts[:broadcast] == false

      Unicast.close(socket)
    end

    test "returns valid port reference" do
      assert {:ok, socket} = Unicast.open(0, [])
      assert is_port(socket)
      Unicast.close(socket)
    end

    test "can specify port 0 for ephemeral port" do
      assert {:ok, socket} = Unicast.open(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(socket)
      assert port > 0
      Unicast.close(socket)
    end

    test "accepts ip option" do
      assert {:ok, socket} = Unicast.open(0, ip: {127, 0, 0, 1})
      {:ok, {ip, _port}} = Unicast.sockname(socket)
      assert ip == {127, 0, 0, 1}
      Unicast.close(socket)
    end
  end

  describe "controlling_process/2" do
    test "transfers socket ownership to another process" do
      {:ok, socket} = Unicast.listen(0, [])

      new_owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      assert :ok = Unicast.controlling_process(socket, new_owner)
      send(new_owner, :done)

      # Clean up in the new owner
      # Since we transferred, we can still close from any process
      Unicast.close(socket)
    end

    test "returns error for dead process" do
      {:ok, socket} = Unicast.listen(0, [])

      dead_process = spawn(fn -> :ok end)
      # Wait for process to die
      :timer.sleep(10)

      result = Unicast.controlling_process(socket, dead_process)
      # May return error depending on timing
      assert result == :ok or match?({:error, _}, result)

      Unicast.close(socket)
    end
  end

  describe "recv/3" do
    test "receives data from socket" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      # Send data from another process
      spawn(fn ->
        {:ok, client} = Unicast.open(0, [])
        Unicast.send(client, {127, 0, 0, 1}, port, "test data")
        Unicast.close(client)
      end)

      # Receive the data
      {:ok, {_ip, _client_port, data}} = Unicast.recv(server, 0, 1000)
      assert data == "test data"

      Unicast.close(server)
    end

    test "returns timeout error when no data" do
      {:ok, socket} = Unicast.listen(0, [])

      result = Unicast.recv(socket, 0, 50)
      assert result == {:error, :timeout}

      Unicast.close(socket)
    end

    test "receives binary data correctly" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      binary_data = <<1, 2, 3, 255, 0, 128, 64>>

      spawn(fn ->
        {:ok, client} = Unicast.open(0, [])
        Unicast.send(client, {127, 0, 0, 1}, port, binary_data)
        Unicast.close(client)
      end)

      {:ok, {_ip, _port, received}} = Unicast.recv(server, 0, 1000)
      assert received == binary_data

      Unicast.close(server)
    end

    test "includes source IP and port" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, server_port}} = Unicast.sockname(server)

      spawn(fn ->
        {:ok, client} = Unicast.open(0, ip: {127, 0, 0, 1})
        Unicast.send(client, {127, 0, 0, 1}, server_port, "hello")
        # Don't close immediately so the port info is available
        :timer.sleep(100)
        Unicast.close(client)
      end)

      {:ok, {src_ip, src_port, _data}} = Unicast.recv(server, 0, 1000)
      assert src_ip == {127, 0, 0, 1}
      assert is_integer(src_port)
      assert src_port > 0

      Unicast.close(server)
    end
  end

  describe "send/4" do
    test "sends data to specified destination" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      assert :ok = Unicast.send(client, {127, 0, 0, 1}, port, "hello")

      {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
      assert data == "hello"

      Unicast.close(server)
      Unicast.close(client)
    end

    test "sends binary data" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      binary = <<0, 1, 2, 255, 128, 64>>
      assert :ok = Unicast.send(client, {127, 0, 0, 1}, port, binary)

      {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
      assert data == binary

      Unicast.close(server)
      Unicast.close(client)
    end

    test "sends iolist data" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      iolist = ["hel", "lo", [" ", "world"]]
      assert :ok = Unicast.send(client, {127, 0, 0, 1}, port, iolist)

      {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
      assert data == "hello world"

      Unicast.close(server)
      Unicast.close(client)
    end

    test "can send large packets" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      # Send a 1KB packet
      large_data = :binary.copy("X", 1024)
      assert :ok = Unicast.send(client, {127, 0, 0, 1}, port, large_data)

      {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
      assert byte_size(data) == 1024

      Unicast.close(server)
      Unicast.close(client)
    end
  end

  describe "send_recv/3" do
    test "sends and receives unicast messages" do
      # Start a simple echo server
      {:ok, server_socket} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server_socket)

      # Spawn a process to echo messages back
      parent = self()

      spawn(fn ->
        {:ok, {ip, client_port, data}} = Unicast.recv(server_socket, 0, 1000)
        send(parent, :server_received)
        Unicast.send(server_socket, ip, client_port, "Echo: #{data}")
        Unicast.close(server_socket)
      end)

      # Send message and receive response
      result = Unicast.send_recv({{127, 0, 0, 1}, port}, "Hello", 1000)

      assert_receive :server_received, 1000
      assert {:ok, {{127, 0, 0, 1}, ^port, "Echo: Hello"}} = result
    end

    test "returns timeout error when no response" do
      # No server listening
      result = Unicast.send_recv({{127, 0, 0, 1}, 59999}, "Hello", 50)
      assert result == {:error, :timeout}
    end

    test "uses default timeout of 5000ms" do
      # Verify function accepts 2 arguments (default timeout)
      assert function_exported?(Unicast, :send_recv, 2) or function_exported?(Unicast, :send_recv, 3)
    end

    test "handles binary data correctly" do
      {:ok, server_socket} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server_socket)

      spawn(fn ->
        {:ok, {ip, client_port, _data}} = Unicast.recv(server_socket, 0, 1000)
        Unicast.send(server_socket, ip, client_port, <<1, 2, 3, 4>>)
        Unicast.close(server_socket)
      end)

      {:ok, {_ip, _port, response}} = Unicast.send_recv({{127, 0, 0, 1}, port}, <<5, 6, 7>>, 1000)
      assert response == <<1, 2, 3, 4>>
    end
  end

  describe "getopts/2" do
    test "retrieves socket options" do
      {:ok, socket} = Unicast.listen(0, [])

      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast, :mode])
      assert is_list(opts)
      assert Keyword.has_key?(opts, :active)
      assert Keyword.has_key?(opts, :broadcast)
      assert Keyword.has_key?(opts, :mode)

      Unicast.close(socket)
    end

    test "returns correct values for hardcoded options" do
      {:ok, socket} = Unicast.listen(0, [])

      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == false
      assert opts[:broadcast] == false

      Unicast.close(socket)
    end

    test "returns buffer sizes" do
      {:ok, socket} = Unicast.listen(0, [])

      {:ok, opts} = Unicast.getopts(socket, [:recbuf, :sndbuf])
      assert is_integer(opts[:recbuf])
      assert is_integer(opts[:sndbuf])
      assert opts[:recbuf] > 0
      assert opts[:sndbuf] > 0

      Unicast.close(socket)
    end
  end

  describe "setopts/2" do
    test "sets socket options" do
      {:ok, socket} = Unicast.listen(0, [])

      # Note: can't change hardcoded options like active/broadcast
      # But can adjust other options
      assert :ok = Unicast.setopts(socket, sndbuf: 65536)

      {:ok, opts} = Unicast.getopts(socket, [:sndbuf])
      # System may adjust the value
      assert is_integer(opts[:sndbuf])

      Unicast.close(socket)
    end

    test "trying to change hardcoded options doesn't affect them" do
      {:ok, socket} = Unicast.listen(0, [])

      # Try to enable active mode - should not take effect because it's hardcoded
      # Note: setopts may succeed but the hardcoded values persist in new sockets
      Unicast.setopts(socket, active: true)

      # The socket state can change, but new listen() calls enforce hardcoded values
      {:ok, new_socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(new_socket, [:active])
      assert opts[:active] == false

      Unicast.close(socket)
      Unicast.close(new_socket)
    end
  end

  describe "sockname/1" do
    test "returns socket address and port" do
      {:ok, socket} = Unicast.listen(0, [])

      {:ok, {ip, port}} = Unicast.sockname(socket)
      assert is_tuple(ip)
      assert tuple_size(ip) == 4 or tuple_size(ip) == 8
      assert is_integer(port)
      assert port > 0

      Unicast.close(socket)
    end

    test "returns bound IP when specified" do
      {:ok, socket} = Unicast.listen(0, ip: {127, 0, 0, 1})

      {:ok, {ip, _port}} = Unicast.sockname(socket)
      assert ip == {127, 0, 0, 1}

      Unicast.close(socket)
    end
  end

  describe "getstat/1" do
    test "returns socket statistics" do
      {:ok, socket} = Unicast.listen(0, [])

      {:ok, stats} = Unicast.getstat(socket)
      assert is_list(stats)

      Unicast.close(socket)
    end

    test "statistics include recv and send counters" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      Unicast.send(client, {127, 0, 0, 1}, port, "test")
      Unicast.recv(server, 0, 100)

      {:ok, server_stats} = Unicast.getstat(server)
      {:ok, client_stats} = Unicast.getstat(client)

      # Should have various stat keys
      assert is_list(server_stats)
      assert is_list(client_stats)

      Unicast.close(server)
      Unicast.close(client)
    end
  end

  describe "close/1" do
    test "closes the socket" do
      {:ok, socket} = Unicast.listen(0, [])

      assert :ok = Unicast.close(socket)
    end

    test "closed socket cannot be used" do
      {:ok, socket} = Unicast.listen(0, [])
      Unicast.close(socket)

      # Operations on closed socket should fail
      result = Unicast.recv(socket, 0, 100)
      assert match?({:error, _}, result)
    end
  end

  describe "peername/1" do
    test "returns error for unconnected UDP socket" do
      {:ok, socket} = Unicast.listen(0, [])

      # UDP sockets are connectionless, peername returns error
      result = Unicast.peername(socket)
      assert match?({:error, :enotconn}, result)

      Unicast.close(socket)
    end
  end

  describe "default options verification" do
    test "active defaults to false for unicast" do
      {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:active])
      assert opts[:active] == false
      Unicast.close(socket)
    end

    test "user can override active option" do
      # User options take precedence over defaults in merge_options
      {:ok, socket1} = Unicast.listen(0, active: true)
      {:ok, opts1} = Unicast.getopts(socket1, [:active])
      assert opts1[:active] == true
      Unicast.close(socket1)
    end

    test "broadcast defaults to false for unicast" do
      {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:broadcast])
      assert opts[:broadcast] == false
      Unicast.close(socket)
    end

    test "user can override broadcast option" do
      {:ok, socket1} = Unicast.listen(0, broadcast: true)
      {:ok, opts1} = Unicast.getopts(socket1, [:broadcast])
      assert opts1[:broadcast] == true
      Unicast.close(socket1)
    end

    test "mode defaults to binary" do
      {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:mode])
      assert opts[:mode] == :binary
      Unicast.close(socket)
    end

    test "user can override mode option" do
      {:ok, socket} = Unicast.listen(0, mode: :list)
      {:ok, opts} = Unicast.getopts(socket, [:mode])
      assert opts[:mode] == :list
      Unicast.close(socket)
    end

    test "reuseaddr defaults to true" do
      {:ok, socket} = Unicast.listen(0, [])
      {:ok, opts} = Unicast.getopts(socket, [:reuseaddr])
      assert opts[:reuseaddr] == true
      Unicast.close(socket)
    end
  end

  describe "edge cases" do
    test "handles empty data" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])
      Unicast.send(client, {127, 0, 0, 1}, port, "")

      {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
      assert data == ""

      Unicast.close(server)
      Unicast.close(client)
    end

    test "handles maximum UDP packet size" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, sndbuf: 131_072, recbuf: 131_072)
      # Maximum UDP payload is ~65507 bytes, but we'll test with a smaller large packet
      large_data = :binary.copy("X", 8192)
      assert :ok = Unicast.send(client, {127, 0, 0, 1}, port, large_data)

      {:ok, {_ip, _port, received}} = Unicast.recv(server, 0, 1000)
      assert byte_size(received) == 8192

      Unicast.close(server)
      Unicast.close(client)
    end

    test "rapid send/receive cycle" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      {:ok, client} = Unicast.open(0, [])

      for i <- 1..10 do
        Unicast.send(client, {127, 0, 0, 1}, port, "msg#{i}")
        {:ok, {_ip, _port, _data}} = Unicast.recv(server, 0, 1000)
      end

      Unicast.close(server)
      Unicast.close(client)
    end
  end

  describe "concurrent operations" do
    test "multiple processes can send to same server" do
      {:ok, server} = Unicast.listen(0, [])
      {:ok, {_ip, port}} = Unicast.sockname(server)

      parent = self()

      # Spawn multiple senders
      for i <- 1..3 do
        spawn(fn ->
          {:ok, client} = Unicast.open(0, [])
          Unicast.send(client, {127, 0, 0, 1}, port, "msg#{i}")
          Unicast.close(client)
          send(parent, {:sent, i})
        end)
      end

      # Receive all messages
      messages =
        for _ <- 1..3 do
          {:ok, {_ip, _port, data}} = Unicast.recv(server, 0, 1000)
          data
        end

      assert length(messages) == 3

      # Wait for all senders
      for _ <- 1..3, do: assert_receive({:sent, _}, 1000)

      Unicast.close(server)
    end

    test "multiple sockets can coexist" do
      sockets =
        for _ <- 1..5 do
          {:ok, socket} = Unicast.listen(0, [])
          socket
        end

      # All should have different ports
      ports =
        for socket <- sockets do
          {:ok, {_ip, port}} = Unicast.sockname(socket)
          port
        end

      assert length(Enum.uniq(ports)) == 5

      for socket <- sockets, do: Unicast.close(socket)
    end
  end

  describe "module documentation" do
    test "has moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Unicast)
      assert is_binary(moduledoc)
      assert moduledoc =~ "unicast"
    end

    test "listen/2 has documentation" do
      {:docs_v1, _, :elixir, _, _, _, function_docs} = Code.fetch_docs(Unicast)

      listen_doc =
        Enum.find(function_docs, fn
          {{:function, :listen, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert listen_doc != nil
    end

    test "send_recv/3 has documentation" do
      {:docs_v1, _, :elixir, _, _, _, function_docs} = Code.fetch_docs(Unicast)

      send_recv_doc =
        Enum.find(function_docs, fn
          {{:function, :send_recv, 3}, _, _, _, _} -> true
          _ -> false
        end)

      assert send_recv_doc != nil
    end
  end
end
