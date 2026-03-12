defmodule YellowDog.Netboot.TFTP.TransferTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.TFTP.{Transfer, Protocol}

  @test_file_content "Hello TFTP World!\n"
  @client_addr {127, 0, 0, 1}
  @client_port 50000

  setup do
    # Create temporary test file
    tmp_dir = System.tmp_dir!()
    file_path = Path.join(tmp_dir, "tftp_test_#{System.unique_integer([:positive])}.txt")
    File.write!(file_path, @test_file_content)

    on_exit(fn ->
      File.rm(file_path)
    end)

    {:ok, file_path: file_path}
  end

  describe "init/1" do
    test "starts transfer with valid file", %{file_path: file_path} do
      args = [
        client_addr: @client_addr,
        client_port: @client_port,
        file_path: file_path,
        block_size: 512
      ]

      assert {:ok, state, timeout} = Transfer.init(args)
      assert state.client_addr == @client_addr
      assert state.client_port == @client_port
      assert state.file_path == file_path
      assert state.file_data == @test_file_content
      assert state.total_size == byte_size(@test_file_content)
      assert state.current_block == 1
      assert state.bytes_sent == 0
      assert state.retries == 0
      assert is_port(state.socket)
      assert timeout == 30_000

      # Clean up
      :gen_udp.close(state.socket)
    end

    test "sends OACK when options provided", %{file_path: file_path} do
      # Start a listener to capture OACK
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 1024,
        options: %{"blksize" => "1024", "tsize" => "#{byte_size(@test_file_content)}"}
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Receive OACK
      {:ok, {_addr, _port, packet}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:oack, opts}} = Protocol.decode(packet)

      assert opts["blksize"] == "1024"
      assert opts["tsize"] == "#{byte_size(@test_file_content)}"

      # Clean up
      :gen_udp.close(state.socket)
      :gen_udp.close(listener)
    end

    test "fails to start with non-existent file and sends ERROR to client" do
      # Use a real listener so we can verify the ERROR packet arrives
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: "/nonexistent/file.txt",
        block_size: 512
      ]

      assert {:stop, {:file_error, :enoent}} = Transfer.init(args)

      # RFC 1350 §4: client must receive an ERROR packet (code 1 = File not found)
      {:ok, {_addr, _port, packet}} = :gen_udp.recv(listener, 0, 1000)
      assert {:ok, {:error, 1, _msg}} = Protocol.decode(packet)

      :gen_udp.close(listener)
    end

    test "sends first data block when no options", %{file_path: file_path} do
      # Start a listener to capture DATA packet
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Receive first DATA block
      {:ok, {_addr, _port, packet}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:data, block_num, data}} = Protocol.decode(packet)

      assert block_num == 1
      assert data == @test_file_content

      # Clean up
      :gen_udp.close(state.socket)
      :gen_udp.close(listener)
    end
  end

  describe "handle_info/2 - ACK processing" do
    setup %{file_path: file_path} do
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Consume first DATA packet
      {:ok, {_addr, port, _packet}} = :gen_udp.recv(listener, 0, 1000)

      on_exit(fn ->
        :gen_udp.close(state.socket)
        :gen_udp.close(listener)
      end)

      {:ok, state: state, listener: listener, server_port: port}
    end

    test "processes ACK for current block", %{state: state, listener: listener, server_port: port} do
      # Send ACK for block 1
      ack_packet = Protocol.encode({:ack, 1})
      :gen_udp.send(listener, @client_addr, port, ack_packet)

      # Simulate receiving the ACK — source port must be state.client_port (RFC 1350 §5 TID check)
      msg = {:udp, state.socket, @client_addr, state.client_port, ack_packet}
      assert {:stop, :normal, _state} = Transfer.handle_info(msg, state)
    end

    test "ignores ACK for wrong block", %{state: state, listener: listener, server_port: port} do
      # Send ACK for wrong block
      ack_packet = Protocol.encode({:ack, 99})
      :gen_udp.send(listener, @client_addr, port, ack_packet)

      # Simulate receiving the wrong ACK — source port must be state.client_port (RFC 1350 §5 TID check)
      msg = {:udp, state.socket, @client_addr, state.client_port, ack_packet}
      assert {:noreply, _state, 30_000} = Transfer.handle_info(msg, state)
    end

    test "processes ACK 0 after OACK", %{file_path: file_path} do
      # Setup with options to trigger OACK
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512,
        options: %{"blksize" => "512"}
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Consume OACK — capture server_port (transfer socket's ephemeral port)
      {:ok, {_addr, server_port, _packet}} = :gen_udp.recv(listener, 0, 1000)

      # Send ACK 0 to the transfer socket
      ack_packet = Protocol.encode({:ack, 0})
      :gen_udp.send(listener, @client_addr, server_port, ack_packet)

      # Simulate receiving ACK 0 — source port must be state.client_port (RFC 1350 §5 TID check)
      msg = {:udp, state.socket, @client_addr, state.client_port, ack_packet}
      assert {:noreply, new_state, 30_000} = Transfer.handle_info(msg, state)
      assert new_state.current_block == 1
      assert new_state.retries == 0

      # Receive first DATA block
      {:ok, {_addr, _port, packet}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:data, block_num, _data}} = Protocol.decode(packet)
      assert block_num == 1

      # Clean up
      :gen_udp.close(state.socket)
      :gen_udp.close(listener)
    end

    test "stops on client ERROR packet", %{state: state, listener: listener, server_port: port} do
      # Send ERROR from client
      error_packet = Protocol.encode({:error, 1, "Client error"})
      :gen_udp.send(listener, @client_addr, port, error_packet)

      # Simulate receiving the ERROR — source port must be state.client_port (RFC 1350 §5 TID check)
      msg = {:udp, state.socket, @client_addr, state.client_port, error_packet}

      assert {:stop, {:client_error, 1, "Client error"}, _state} =
               Transfer.handle_info(msg, state)
    end
  end

  describe "handle_info/2 - timeout and retry" do
    setup %{file_path: file_path} do
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Consume first DATA packet
      {:ok, _} = :gen_udp.recv(listener, 0, 1000)

      on_exit(fn ->
        :gen_udp.close(state.socket)
        :gen_udp.close(listener)
      end)

      {:ok, state: state, listener: listener}
    end

    test "retries on timeout", %{state: state, listener: listener} do
      # Simulate timeout
      assert {:noreply, new_state, 30_000} = Transfer.handle_info(:timeout, state)
      assert new_state.retries == 1

      # Should resend current block
      {:ok, {_addr, _port, packet}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:data, block_num, _data}} = Protocol.decode(packet)
      assert block_num == 1
    end

    test "stops after max retries", %{state: state} do
      # Set retries to max
      state = %{state | retries: 5}

      # Simulate timeout
      assert {:stop, :timeout, _state} = Transfer.handle_info(:timeout, state)
    end

    test "retries multiple times before giving up", %{state: state, listener: listener} do
      # Retry 4 times (under the limit)
      state1 = elem(Transfer.handle_info(:timeout, state), 1)
      assert state1.retries == 1
      {:ok, _} = :gen_udp.recv(listener, 0, 1000)

      state2 = elem(Transfer.handle_info(:timeout, state1), 1)
      assert state2.retries == 2
      {:ok, _} = :gen_udp.recv(listener, 0, 1000)

      state3 = elem(Transfer.handle_info(:timeout, state2), 1)
      assert state3.retries == 3
      {:ok, _} = :gen_udp.recv(listener, 0, 1000)

      state4 = elem(Transfer.handle_info(:timeout, state3), 1)
      assert state4.retries == 4
      {:ok, _} = :gen_udp.recv(listener, 0, 1000)

      # 5th timeout should stop
      state5 = %{state4 | retries: 5}
      assert {:stop, :timeout, _} = Transfer.handle_info(:timeout, state5)
    end
  end

  describe "handle_info/2 - OACK timeout retry" do
    test "timeout during OACK wait retransmits OACK (not a DATA block)", %{file_path: file_path} do
      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512,
        options: %{"blksize" => "512"}
      ]

      {:ok, state, _timeout} = Transfer.init(args)
      assert state.current_block == 0

      # Consume initial OACK
      {:ok, {_addr, _port, initial_oack}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:oack, _}} = Protocol.decode(initial_oack)

      # Simulate timeout while waiting for ACK 0 — must NOT crash (previous bug:
      # send_next_block with current_block=0 computed negative offset for binary_part)
      assert {:noreply, new_state, 30_000} = Transfer.handle_info(:timeout, state)
      assert new_state.retries == 1

      # Must resend OACK, not a DATA block
      {:ok, {_addr, _port, retransmit}} = :gen_udp.recv(listener, 0, 1000)
      assert {:ok, {:oack, opts}} = Protocol.decode(retransmit)
      assert opts["blksize"] == "512"

      :gen_udp.close(state.socket)
      :gen_udp.close(listener)
    end
  end

  describe "multi-block transfer" do
    test "transfers file larger than block size" do
      # Create large file (1.5 blocks)
      tmp_dir = System.tmp_dir!()
      file_path = Path.join(tmp_dir, "large_#{System.unique_integer([:positive])}.bin")
      large_content = :crypto.strong_rand_bytes(768)
      File.write!(file_path, large_content)

      {:ok, listener} = :gen_udp.open(0, [:binary, active: false])
      {:ok, listener_port} = :inet.port(listener)

      args = [
        client_addr: @client_addr,
        client_port: listener_port,
        file_path: file_path,
        block_size: 512
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Receive block 1 — capture server_port (transfer socket's ephemeral port)
      {:ok, {_addr, server_port, packet1}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:data, 1, data1}} = Protocol.decode(packet1)
      assert byte_size(data1) == 512

      # Send ACK for block 1 to the transfer socket; simulate as coming from client_port (RFC 1350 §5)
      ack1 = Protocol.encode({:ack, 1})
      :gen_udp.send(listener, @client_addr, server_port, ack1)
      msg1 = {:udp, state.socket, @client_addr, state.client_port, ack1}
      {:noreply, state2, _} = Transfer.handle_info(msg1, state)

      # Receive block 2 (last block, smaller)
      {:ok, {_addr, _port, packet2}} = :gen_udp.recv(listener, 0, 1000)
      {:ok, {:data, 2, data2}} = Protocol.decode(packet2)
      assert byte_size(data2) == 256

      # Send ACK for block 2 to the transfer socket; simulate as coming from client_port
      ack2 = Protocol.encode({:ack, 2})
      :gen_udp.send(listener, @client_addr, server_port, ack2)
      msg2 = {:udp, state2.socket, @client_addr, state2.client_port, ack2}
      assert {:stop, :normal, _} = Transfer.handle_info(msg2, state2)

      # Verify full content
      assert data1 <> data2 == large_content

      # Clean up
      :gen_udp.close(state.socket)
      :gen_udp.close(listener)
      File.rm(file_path)
    end
  end

  describe "block number rollover" do
    test "ACK 0 is accepted when current_block has rolled over past 65535", %{
      file_path: file_path
    } do
      # Construct state as if we just sent block 65536 (wire block 0)
      {:ok, state, _} =
        Transfer.init([
          client_addr: @client_addr,
          client_port: @client_port,
          file_path: file_path,
          block_size: 512
        ])

      state = %{state | current_block: 65536}

      # Client sends ACK 0 (which is the wire representation of logical block 65536)
      ack_packet = Protocol.encode({:ack, 0})
      msg = {:udp, state.socket, @client_addr, @client_port, ack_packet}

      # Must be accepted — transfer_complete? is true for this tiny file,
      # so we expect {:stop, :normal, _} rather than an ignored noreply
      assert {:stop, :normal, _new_state} = Transfer.handle_info(msg, state)

      :gen_udp.close(state.socket)
    end

    test "wire block number wraps to 0 when logical block is 65536", _ctx do
      # Verify Protocol.encode uses rem-wrapped block, not raw logical block
      # encode({:data, 65536, data}) must produce the same bytes as encode({:data, 0, data})
      data = "x"
      packet_0 = Protocol.encode({:data, 0, data})
      packet_overflow = Protocol.encode({:data, 65536, data})
      assert packet_0 == packet_overflow
    end
  end

  describe "terminate/2" do
    test "closes socket on termination", %{file_path: file_path} do
      args = [
        client_addr: @client_addr,
        client_port: @client_port,
        file_path: file_path,
        block_size: 512
      ]

      {:ok, state, _timeout} = Transfer.init(args)

      # Verify socket is open
      assert {:ok, _} = :inet.port(state.socket)

      # Terminate
      Transfer.terminate(:normal, state)

      # Verify socket is closed
      assert {:error, :einval} = :inet.port(state.socket)
    end

    test "handles termination with nil socket" do
      state = %Transfer{socket: nil}
      assert :ok = Transfer.terminate(:normal, state)
    end
  end
end
