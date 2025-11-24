defmodule Abyss.Transport.UDP.UnicastTest do
  use ExUnit.Case, async: true

  alias Abyss.Transport.UDP.Unicast

  describe "listen/2" do
    test "creates unicast socket with correct options" do
      assert {:ok, socket} = Unicast.listen(0, [])

      # Verify unicast-specific options
      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == false
      assert opts[:broadcast] == false

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
  end

  describe "open/2" do
    test "opens unicast socket for sending" do
      assert {:ok, socket} = Unicast.open(0, [])

      {:ok, opts} = Unicast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == false
      assert opts[:broadcast] == false

      Unicast.close(socket)
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
  end

  describe "transport behaviour" do
    test "implements all required callbacks" do
      {:ok, socket} = Unicast.listen(0, [])

      # Test controlling_process
      assert :ok = Unicast.controlling_process(socket, self())

      # Test getopts
      assert {:ok, _opts} = Unicast.getopts(socket, [:active])

      # Test setopts
      assert :ok = Unicast.setopts(socket, active: false)

      # Test sockname
      assert {:ok, {_ip, _port}} = Unicast.sockname(socket)

      # Test getstat
      assert {:ok, _stats} = Unicast.getstat(socket)

      # Test close
      assert :ok = Unicast.close(socket)
    end
  end
end
