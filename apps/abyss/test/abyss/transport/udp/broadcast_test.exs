defmodule Abyss.Transport.UDP.BroadcastTest do
  use ExUnit.Case, async: true

  alias Abyss.Transport.UDP.Broadcast

  describe "listen/2" do
    test "creates broadcast socket with correct options" do
      assert {:ok, socket} = Broadcast.listen(0, [])

      # Verify broadcast-specific options
      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == true
      assert opts[:broadcast] == true

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
  end

  describe "open/2" do
    test "opens broadcast socket for sending" do
      assert {:ok, socket} = Broadcast.open(0, [])

      {:ok, opts} = Broadcast.getopts(socket, [:active, :broadcast])
      assert opts[:active] == true
      assert opts[:broadcast] == true

      Broadcast.close(socket)
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
end
