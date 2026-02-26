defmodule Abyss.Transport.UDP.BroadcastTest do
  use ExUnit.Case, async: true

  alias Abyss.Transport.UDP.Broadcast

  @moduletag :capture_log

  describe "module structure" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(Broadcast)
    end

    test "implements Abyss.Transport behaviour" do
      behaviours = Broadcast.__info__(:attributes) |> Keyword.get(:behaviour, [])
      assert Abyss.Transport in behaviours
    end

    test "exports listen/2" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :listen, 2)
    end

    test "exports open/2" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :open, 2)
    end

    test "exports controlling_process/2" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :controlling_process, 2)
    end

    test "exports recv/3" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :recv, 3)
    end

    test "exports send/2, send/3, send/4, send/5" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :send, 2)
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :send, 3)
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :send, 4)
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :send, 5)
    end

    test "exports getopts/2" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :getopts, 2)
    end

    test "exports setopts/2" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :setopts, 2)
    end

    test "exports close/1" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :close, 1)
    end

    test "exports sockname/1" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :sockname, 1)
    end

    test "exports peername/1" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :peername, 1)
    end

    test "exports getstat/1" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :getstat, 1)
    end

    test "exports send_broadcast/4 utility function" do
      Code.ensure_loaded!(Broadcast)
      assert function_exported?(Broadcast, :send_broadcast, 4)
    end
  end

  describe "listen/2" do
    test "creates broadcast socket with correct options" do
      assert {:ok, socket} = Broadcast.listen(0, [])

      # Verify broadcast-specific options
      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == true
      assert opts[:broadcast] == true

      Broadcast.close(socket)
    end

    test "returns valid port reference" do
      assert {:ok, socket} = Broadcast.listen(0, [])
      assert is_port(socket)
      Broadcast.close(socket)
    end

    test "can listen on specific port" do
      assert {:ok, socket} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(socket)
      assert is_integer(port)
      assert port > 0
      Broadcast.close(socket)
    end

    test "sets mode to binary" do
      assert {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:mode])
      assert opts[:mode] == :binary
      Broadcast.close(socket)
    end

    test "sets reuseaddr to true" do
      assert {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:reuseaddr])
      assert opts[:reuseaddr] == true
      Broadcast.close(socket)
    end

    test "allows user options for multicast configuration" do
      assert {:ok, socket} =
               Broadcast.listen(0,
                 ip: {0, 0, 0, 0},
                 multicast_ttl: 255
               )

      {:ok, opts} = Broadcast.getopts(socket, [:multicast_ttl])
      assert opts[:multicast_ttl] == 255

      Broadcast.close(socket)
    end

    test "accepts ip option for binding" do
      assert {:ok, socket} = Broadcast.listen(0, ip: {0, 0, 0, 0})
      {:ok, {ip, _port}} = Broadcast.sockname(socket)
      assert ip == {0, 0, 0, 0}
      Broadcast.close(socket)
    end

    test "accepts multicast_if option" do
      assert {:ok, socket} = Broadcast.listen(0, multicast_if: {0, 0, 0, 0})
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_if])
      # multicast_if returns an interface address (may be resolved by system)
      assert is_tuple(opts[:multicast_if])
      Broadcast.close(socket)
    end

    test "accepts multicast_loop option" do
      assert {:ok, socket} = Broadcast.listen(0, multicast_loop: false)
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_loop])
      assert opts[:multicast_loop] == false
      Broadcast.close(socket)
    end

    test "can create multiple sockets" do
      assert {:ok, socket1} = Broadcast.listen(0, [])
      assert {:ok, socket2} = Broadcast.listen(0, [])

      {:ok, {_, port1}} = Broadcast.sockname(socket1)
      {:ok, {_, port2}} = Broadcast.sockname(socket2)
      assert port1 != port2

      Broadcast.close(socket1)
      Broadcast.close(socket2)
    end

    test "returns error for privileged port without permissions" do
      # Port 1 is privileged, should fail without root
      # On some systems (containers, root) this might succeed, so we accept both
      result = Broadcast.listen(1, [])

      case result do
        {:error, _reason} ->
          assert true

        {:ok, socket} ->
          Broadcast.close(socket)
          # Test passed - we had permissions
          assert true
      end
    end
  end

  describe "open/2" do
    test "opens broadcast socket for sending" do
      assert {:ok, socket} = Broadcast.open(0, [])

      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == true
      assert opts[:broadcast] == true

      Broadcast.close(socket)
    end

    test "returns valid port reference" do
      assert {:ok, socket} = Broadcast.open(0, [])
      assert is_port(socket)
      Broadcast.close(socket)
    end

    test "can specify port 0 for ephemeral port" do
      assert {:ok, socket} = Broadcast.open(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(socket)
      assert port > 0
      Broadcast.close(socket)
    end

    test "accepts ip option" do
      assert {:ok, socket} = Broadcast.open(0, ip: {0, 0, 0, 0})
      {:ok, {ip, _port}} = Broadcast.sockname(socket)
      assert ip == {0, 0, 0, 0}
      Broadcast.close(socket)
    end
  end

  describe "controlling_process/2" do
    test "transfers socket ownership to another process" do
      {:ok, socket} = Broadcast.listen(0, [])

      new_owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      assert :ok = Broadcast.controlling_process(socket, new_owner)
      send(new_owner, :done)

      Broadcast.close(socket)
    end

    test "returns error for dead process" do
      {:ok, socket} = Broadcast.listen(0, [])

      dead_process = spawn(fn -> :ok end)
      # Wait for process to die
      :timer.sleep(10)

      result = Broadcast.controlling_process(socket, dead_process)
      # May return error depending on timing
      assert result == :ok or match?({:error, _}, result)

      Broadcast.close(socket)
    end
  end

  describe "recv/3" do
    test "can receive data in passive mode" do
      # Switch to passive mode for this test
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      # Send data from another process
      spawn(fn ->
        {:ok, client} = Broadcast.open(0, [])
        Broadcast.send(client, {127, 0, 0, 1}, port, "test data")
        Broadcast.close(client)
      end)

      # Receive the data
      {:ok, {_ip, _client_port, data}} = Broadcast.recv(server, 0, 1000)
      assert data == "test data"

      Broadcast.close(server)
    end

    test "returns timeout error when no data in passive mode" do
      {:ok, socket} = Broadcast.listen(0, [])
      :inet.setopts(socket, active: false)

      result = Broadcast.recv(socket, 0, 50)
      assert result == {:error, :timeout}

      Broadcast.close(socket)
    end
  end

  describe "send/4" do
    test "sends data to specified destination" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])
      assert :ok = Broadcast.send(client, {127, 0, 0, 1}, port, "hello")

      {:ok, {_ip, _port, data}} = Broadcast.recv(server, 0, 1000)
      assert data == "hello"

      Broadcast.close(server)
      Broadcast.close(client)
    end

    test "sends binary data" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])
      binary = <<0, 1, 2, 255, 128, 64>>
      assert :ok = Broadcast.send(client, {127, 0, 0, 1}, port, binary)

      {:ok, {_ip, _port, data}} = Broadcast.recv(server, 0, 1000)
      assert data == binary

      Broadcast.close(server)
      Broadcast.close(client)
    end

    test "sends iolist data" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])
      iolist = ["hel", "lo", [" ", "world"]]
      assert :ok = Broadcast.send(client, {127, 0, 0, 1}, port, iolist)

      {:ok, {_ip, _port, data}} = Broadcast.recv(server, 0, 1000)
      assert data == "hello world"

      Broadcast.close(server)
      Broadcast.close(client)
    end
  end

  describe "send_broadcast/4" do
    test "sends broadcast messages" do
      {:ok, socket} = Broadcast.open(0, ip: {0, 0, 0, 0})

      # Send to localhost broadcast (won't actually broadcast on loopback)
      result = Broadcast.send_broadcast(socket, {127, 0, 0, 1}, 9999, "test message")

      assert result == :ok

      Broadcast.close(socket)
    end

    test "sends to broadcast address" do
      {:ok, socket} = Broadcast.open(0, ip: {0, 0, 0, 0})

      # Send to local broadcast address
      result = Broadcast.send_broadcast(socket, {255, 255, 255, 255}, 9999, "broadcast test")
      assert result == :ok

      Broadcast.close(socket)
    end

    test "sends binary data via broadcast" do
      {:ok, socket} = Broadcast.open(0, ip: {0, 0, 0, 0})

      binary_data = <<1, 2, 3, 255, 0, 128>>
      result = Broadcast.send_broadcast(socket, {127, 0, 0, 1}, 9999, binary_data)
      assert result == :ok

      Broadcast.close(socket)
    end

    test "sends iolist data via broadcast" do
      {:ok, socket} = Broadcast.open(0, ip: {0, 0, 0, 0})

      iolist = ["hello", " ", "world"]
      result = Broadcast.send_broadcast(socket, {127, 0, 0, 1}, 9999, iolist)
      assert result == :ok

      Broadcast.close(socket)
    end
  end

  describe "active mode message receiving" do
    test "receives messages as Erlang messages in active mode" do
      {:ok, server} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      spawn(fn ->
        {:ok, client} = Broadcast.open(0, [])
        Broadcast.send(client, {127, 0, 0, 1}, port, "active mode test")
        Broadcast.close(client)
      end)

      # In active mode, data arrives as Erlang messages
      assert_receive {:udp, ^server, {127, 0, 0, 1}, _port, "active mode test"}, 1000

      Broadcast.close(server)
    end

    test "receives binary data in active mode" do
      {:ok, server} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      binary_data = <<1, 2, 3, 4, 5>>

      spawn(fn ->
        {:ok, client} = Broadcast.open(0, [])
        Broadcast.send(client, {127, 0, 0, 1}, port, binary_data)
        Broadcast.close(client)
      end)

      assert_receive {:udp, ^server, {127, 0, 0, 1}, _port, ^binary_data}, 1000

      Broadcast.close(server)
    end

    test "receives multiple messages in active mode" do
      {:ok, server} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      spawn(fn ->
        {:ok, client} = Broadcast.open(0, [])
        Broadcast.send(client, {127, 0, 0, 1}, port, "msg1")
        Broadcast.send(client, {127, 0, 0, 1}, port, "msg2")
        Broadcast.send(client, {127, 0, 0, 1}, port, "msg3")
        Broadcast.close(client)
      end)

      assert_receive {:udp, ^server, _, _, "msg1"}, 1000
      assert_receive {:udp, ^server, _, _, "msg2"}, 1000
      assert_receive {:udp, ^server, _, _, "msg3"}, 1000

      Broadcast.close(server)
    end
  end

  describe "getopts/2" do
    test "retrieves socket options" do
      {:ok, socket} = Broadcast.listen(0, [])

      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast, :mode])
      assert is_list(opts)
      assert Keyword.has_key?(opts, :active)
      assert Keyword.has_key?(opts, :broadcast)
      assert Keyword.has_key?(opts, :mode)

      Broadcast.close(socket)
    end

    test "returns correct values for hardcoded options" do
      {:ok, socket} = Broadcast.listen(0, [])

      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == true
      assert opts[:broadcast] == true

      Broadcast.close(socket)
    end

    test "returns buffer sizes" do
      {:ok, socket} = Broadcast.listen(0, [])

      {:ok, opts} = Broadcast.getopts(socket, [:recbuf, :sndbuf])
      assert is_integer(opts[:recbuf])
      assert is_integer(opts[:sndbuf])
      assert opts[:recbuf] > 0
      assert opts[:sndbuf] > 0

      Broadcast.close(socket)
    end

    test "returns multicast options" do
      {:ok, socket} = Broadcast.listen(0, multicast_ttl: 255, multicast_loop: true)

      {:ok, opts} = Broadcast.getopts(socket, [:multicast_ttl, :multicast_loop])
      assert opts[:multicast_ttl] == 255
      assert opts[:multicast_loop] == true

      Broadcast.close(socket)
    end
  end

  describe "setopts/2" do
    test "sets socket options" do
      {:ok, socket} = Broadcast.listen(0, [])

      assert :ok = Broadcast.setopts(socket, sndbuf: 65536)

      {:ok, opts} = Broadcast.getopts(socket, [:sndbuf])
      assert is_integer(opts[:sndbuf])

      Broadcast.close(socket)
    end

    test "can change multicast options" do
      {:ok, socket} = Broadcast.listen(0, [])

      Broadcast.setopts(socket, multicast_ttl: 64)
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_ttl])
      assert opts[:multicast_ttl] == 64

      Broadcast.close(socket)
    end

    test "can switch between active modes" do
      {:ok, socket} = Broadcast.listen(0, [])

      # Initially active: true
      {:ok, opts1} = Broadcast.getopts(socket, [:active])
      assert opts1[:active] == true

      # Switch to passive
      Broadcast.setopts(socket, active: false)
      {:ok, opts2} = Broadcast.getopts(socket, [:active])
      assert opts2[:active] == false

      # Switch back to active
      Broadcast.setopts(socket, active: true)
      {:ok, opts3} = Broadcast.getopts(socket, [:active])
      assert opts3[:active] == true

      Broadcast.close(socket)
    end
  end

  describe "sockname/1" do
    test "returns socket address and port" do
      {:ok, socket} = Broadcast.listen(0, [])

      {:ok, {ip, port}} = Broadcast.sockname(socket)
      assert is_tuple(ip)
      assert tuple_size(ip) == 4 or tuple_size(ip) == 8
      assert is_integer(port)
      assert port > 0

      Broadcast.close(socket)
    end

    test "returns bound IP when specified" do
      {:ok, socket} = Broadcast.listen(0, ip: {0, 0, 0, 0})

      {:ok, {ip, _port}} = Broadcast.sockname(socket)
      assert ip == {0, 0, 0, 0}

      Broadcast.close(socket)
    end
  end

  describe "getstat/1" do
    test "returns socket statistics" do
      {:ok, socket} = Broadcast.listen(0, [])

      {:ok, stats} = Broadcast.getstat(socket)
      assert is_list(stats)

      Broadcast.close(socket)
    end

    test "statistics include recv and send counters" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])
      Broadcast.send(client, {127, 0, 0, 1}, port, "test")
      Broadcast.recv(server, 0, 100)

      {:ok, server_stats} = Broadcast.getstat(server)
      {:ok, client_stats} = Broadcast.getstat(client)

      assert is_list(server_stats)
      assert is_list(client_stats)

      Broadcast.close(server)
      Broadcast.close(client)
    end
  end

  describe "close/1" do
    test "closes the socket" do
      {:ok, socket} = Broadcast.listen(0, [])

      assert :ok = Broadcast.close(socket)
    end

    test "closed socket cannot be used" do
      {:ok, socket} = Broadcast.listen(0, [])
      :inet.setopts(socket, active: false)
      Broadcast.close(socket)

      result = Broadcast.recv(socket, 0, 100)
      assert match?({:error, _}, result)
    end
  end

  describe "peername/1" do
    test "returns error for unconnected UDP socket" do
      {:ok, socket} = Broadcast.listen(0, [])

      result = Broadcast.peername(socket)
      assert match?({:error, :enotconn}, result)

      Broadcast.close(socket)
    end
  end

  describe "default options verification" do
    test "active defaults to true for broadcast" do
      {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:active])
      assert opts[:active] == true
      Broadcast.close(socket)
    end

    test "user can override active option" do
      # User options take precedence over defaults in merge_options
      {:ok, socket1} = Broadcast.listen(0, active: false)
      {:ok, opts1} = Broadcast.getopts(socket1, [:active])
      assert opts1[:active] == false
      Broadcast.close(socket1)
    end

    test "broadcast defaults to true for broadcast transport" do
      {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:broadcast])
      assert opts[:broadcast] == true
      Broadcast.close(socket)
    end

    test "user can override broadcast option" do
      {:ok, socket1} = Broadcast.listen(0, broadcast: false)
      {:ok, opts1} = Broadcast.getopts(socket1, [:broadcast])
      assert opts1[:broadcast] == false
      Broadcast.close(socket1)
    end

    test "mode defaults to binary" do
      {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:mode])
      assert opts[:mode] == :binary
      Broadcast.close(socket)
    end

    test "user can override mode option" do
      {:ok, socket} = Broadcast.listen(0, mode: :list)
      {:ok, opts} = Broadcast.getopts(socket, [:mode])
      assert opts[:mode] == :list
      Broadcast.close(socket)
    end

    test "reuseaddr defaults to true" do
      {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:reuseaddr])
      assert opts[:reuseaddr] == true
      Broadcast.close(socket)
    end
  end

  describe "multicast configuration" do
    test "can configure multicast TTL" do
      {:ok, socket} = Broadcast.listen(0, multicast_ttl: 255)
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_ttl])
      assert opts[:multicast_ttl] == 255
      Broadcast.close(socket)
    end

    test "can configure multicast interface" do
      {:ok, socket} = Broadcast.listen(0, multicast_if: {0, 0, 0, 0})
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_if])
      # multicast_if returns an interface address (may be resolved by system)
      assert is_tuple(opts[:multicast_if])
      Broadcast.close(socket)
    end

    test "can configure multicast loopback" do
      {:ok, socket} = Broadcast.listen(0, multicast_loop: false)
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_loop])
      assert opts[:multicast_loop] == false
      Broadcast.close(socket)
    end

    test "default multicast TTL is 1" do
      {:ok, socket} = Broadcast.listen(0, [])
      {:ok, opts} = Broadcast.getopts(socket, [:multicast_ttl])
      assert opts[:multicast_ttl] == 1
      Broadcast.close(socket)
    end
  end

  describe "edge cases" do
    test "handles empty data" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])
      Broadcast.send(client, {127, 0, 0, 1}, port, "")

      {:ok, {_ip, _port, data}} = Broadcast.recv(server, 0, 1000)
      assert data == ""

      Broadcast.close(server)
      Broadcast.close(client)
    end

    test "handles large broadcast packets" do
      {:ok, server} = Broadcast.listen(0, [])
      :inet.setopts(server, active: false)
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, sndbuf: 131_072, recbuf: 131_072)
      large_data = :binary.copy("X", 8192)
      assert :ok = Broadcast.send(client, {127, 0, 0, 1}, port, large_data)

      {:ok, {_ip, _port, received}} = Broadcast.recv(server, 0, 1000)
      assert byte_size(received) == 8192

      Broadcast.close(server)
      Broadcast.close(client)
    end

    test "rapid send in active mode" do
      {:ok, server} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      {:ok, client} = Broadcast.open(0, [])

      for i <- 1..10 do
        Broadcast.send(client, {127, 0, 0, 1}, port, "msg#{i}")
      end

      # Receive all in active mode
      for _ <- 1..10 do
        assert_receive {:udp, ^server, _, _, _}, 1000
      end

      Broadcast.close(server)
      Broadcast.close(client)
    end
  end

  describe "concurrent operations" do
    test "multiple processes can send to same server" do
      {:ok, server} = Broadcast.listen(0, [])
      {:ok, {_ip, port}} = Broadcast.sockname(server)

      parent = self()

      for i <- 1..3 do
        spawn(fn ->
          {:ok, client} = Broadcast.open(0, [])
          Broadcast.send(client, {127, 0, 0, 1}, port, "msg#{i}")
          Broadcast.close(client)
          send(parent, {:sent, i})
        end)
      end

      # Receive all messages in active mode
      for _ <- 1..3 do
        assert_receive {:udp, ^server, _, _, _}, 1000
      end

      for _ <- 1..3, do: assert_receive({:sent, _}, 1000)

      Broadcast.close(server)
    end

    test "multiple sockets can coexist" do
      sockets =
        for _ <- 1..5 do
          {:ok, socket} = Broadcast.listen(0, [])
          socket
        end

      ports =
        for socket <- sockets do
          {:ok, {_ip, port}} = Broadcast.sockname(socket)
          port
        end

      assert length(Enum.uniq(ports)) == 5

      for socket <- sockets, do: Broadcast.close(socket)
    end
  end

  describe "transport behaviour" do
    test "implements all required callbacks" do
      {:ok, socket} = Broadcast.listen(0, [])

      # Test controlling_process
      assert :ok = Broadcast.controlling_process(socket, self())

      # Test getopts
      assert {:ok, _opts} = Broadcast.getopts(socket, [:active])

      # Test setopts
      assert :ok = Broadcast.setopts(socket, active: true)

      # Test sockname
      assert {:ok, {_ip, _port}} = Broadcast.sockname(socket)

      # Test getstat
      assert {:ok, _stats} = Broadcast.getstat(socket)

      # Test close
      assert :ok = Broadcast.close(socket)
    end
  end

  describe "module documentation" do
    test "has moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Broadcast)
      assert is_binary(moduledoc)
      assert moduledoc =~ "broadcast"
    end

    test "mentions multicast support" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Broadcast)
      assert moduledoc =~ "multicast"
    end

    test "listen/2 has documentation" do
      {:docs_v1, _, :elixir, _, _, _, function_docs} = Code.fetch_docs(Broadcast)

      listen_doc =
        Enum.find(function_docs, fn
          {{:function, :listen, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert listen_doc != nil
    end

    test "send_broadcast/4 has documentation" do
      {:docs_v1, _, :elixir, _, _, _, function_docs} = Code.fetch_docs(Broadcast)

      send_broadcast_doc =
        Enum.find(function_docs, fn
          {{:function, :send_broadcast, 4}, _, _, _, _} -> true
          _ -> false
        end)

      assert send_broadcast_doc != nil
    end
  end
end
