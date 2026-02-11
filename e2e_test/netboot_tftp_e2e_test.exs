defmodule E2ETest.NetbootTftpE2ETest do
  @moduledoc """
  End-to-end tests for the YellowDog Netboot TFTP Server.

  Tests the TFTP server by starting it with a temp root directory,
  sending raw TFTP RRQ packets over UDP, and verifying file content
  is received correctly.

  These tests verify:
  - Server starts and binds to a port
  - RRQ (read) requests receive file content via DATA packets
  - WRQ (write) requests are rejected
  - Non-existent files return error
  - Path traversal attempts are rejected
  - Option negotiation (blksize, tsize) works
  - Large file transfers spanning multiple blocks
  """

  use ExUnit.Case, async: false

  alias YellowDog.Netboot.TFTP.{Protocol, FileIndex}

  @moduletag :e2e
  @moduletag :netboot

  @recv_timeout 5_000

  setup_all do
    # Create temporary TFTP root with test files
    tmp_dir = Path.join(System.tmp_dir!(), "yellow_dog_tftp_e2e_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    small_content = "Hello, TFTP world!"
    File.write!(Path.join(tmp_dir, "small.txt"), small_content)

    # Large file that spans multiple 512-byte blocks (4096 chars hex = 2048 bytes random)
    large_content = :crypto.strong_rand_bytes(2048) |> Base.encode16()
    File.write!(Path.join(tmp_dir, "large.bin"), large_content)

    nested_dir = Path.join(tmp_dir, "subdir")
    File.mkdir_p!(nested_dir)
    nested_content = "nested file content"
    File.write!(Path.join(nested_dir, "nested.txt"), nested_content)

    # Exactly 512 bytes — block boundary case
    exact_block = String.duplicate("A", 512)
    File.write!(Path.join(tmp_dir, "exact512.bin"), exact_block)

    # Initialize FileIndex ETS table
    FileIndex.init()

    # Start TransferSupervisor (DynamicSupervisor for per-transfer workers)
    {:ok, transfer_sup} = YellowDog.Netboot.TFTP.TransferSupervisor.start_link([])

    # Start TFTP server on auto-selected port
    config = %{tftp_port: 0, tftp_root: tmp_dir}
    {:ok, server_pid} = YellowDog.Netboot.TFTP.Server.start_link(config: config)

    %{port: port} = YellowDog.Netboot.TFTP.Server.status()

    on_exit(fn ->
      safe_stop(server_pid)
      safe_stop(transfer_sup)
      File.rm_rf!(tmp_dir)
    end)

    {:ok,
     %{
       port: port,
       host: {127, 0, 0, 1},
       tmp_dir: tmp_dir,
       small_content: small_content,
       large_content: large_content,
       nested_content: nested_content,
       exact_block: exact_block
     }}
  end

  describe "TFTP server lifecycle" do
    test "server starts and reports running status", ctx do
      status = YellowDog.Netboot.TFTP.Server.status()

      assert status.running == true
      assert status.port == ctx.port
      assert status.port > 0
      assert status.file_count > 0
    end
  end

  describe "RRQ file transfer" do
    test "reads a small file in one block", ctx do
      assert {:ok, data} = tftp_read(ctx.host, ctx.port, "small.txt")
      assert data == ctx.small_content
    end

    test "reads a large file spanning multiple blocks", ctx do
      assert {:ok, data} = tftp_read(ctx.host, ctx.port, "large.bin")
      assert data == ctx.large_content
    end

    test "reads a file from nested directory", ctx do
      assert {:ok, data} = tftp_read(ctx.host, ctx.port, "subdir/nested.txt")
      assert data == ctx.nested_content
    end

    test "reads exact-512-byte file (block boundary)", ctx do
      assert {:ok, data} = tftp_read(ctx.host, ctx.port, "exact512.bin")
      assert data == ctx.exact_block
    end
  end

  describe "error handling" do
    test "returns error for non-existent file", ctx do
      assert {:error, 1, _message} = tftp_read(ctx.host, ctx.port, "nonexistent.txt")
    end

    test "rejects path traversal attempts", ctx do
      result = tftp_read(ctx.host, ctx.port, "../../../etc/passwd")
      # Should get access violation (2) or file not found (1)
      assert {:error, code, _message} = result
      assert code in [1, 2]
    end

    test "rejects WRQ (write) requests", ctx do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

      # Build WRQ packet: opcode 2 | filename | 0 | mode | 0
      packet = <<0, 2, "test.txt", 0, "octet", 0>>
      :ok = :gen_udp.send(socket, ctx.host, ctx.port, packet)

      # Error comes from the server socket (same port), not a transfer worker
      assert {:ok, {_addr, _port, response}} = :gen_udp.recv(socket, 0, @recv_timeout)
      {:ok, {:error, 2, _msg}} = Protocol.decode(response)

      :gen_udp.close(socket)
    end
  end

  describe "option negotiation" do
    test "negotiates blksize option", ctx do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

      # RRQ with blksize option
      packet = <<0, 1, "small.txt", 0, "octet", 0, "blksize", 0, "1024", 0>>
      :ok = :gen_udp.send(socket, ctx.host, ctx.port, packet)

      # OACK comes from the transfer worker's ephemeral port
      assert {:ok, {_addr, transfer_port, response}} = :gen_udp.recv(socket, 0, @recv_timeout)
      {:ok, {:oack, opts}} = Protocol.decode(response)
      assert opts["blksize"] == "1024"

      # ACK the OACK (block 0) to start data transfer
      ack = Protocol.encode({:ack, 0})
      :ok = :gen_udp.send(socket, ctx.host, transfer_port, ack)

      # Receive data from the same transfer port
      assert {:ok, {_addr, _port, data_packet}} = :gen_udp.recv(socket, 0, @recv_timeout)
      {:ok, {:data, 1, data}} = Protocol.decode(data_packet)
      assert data == ctx.small_content

      :gen_udp.close(socket)
    end

    test "negotiates tsize option", ctx do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

      # RRQ with tsize option (value 0 = "tell me the size")
      packet = <<0, 1, "small.txt", 0, "octet", 0, "tsize", 0, "0", 0>>
      :ok = :gen_udp.send(socket, ctx.host, ctx.port, packet)

      assert {:ok, {_addr, _port, response}} = :gen_udp.recv(socket, 0, @recv_timeout)
      {:ok, {:oack, opts}} = Protocol.decode(response)
      assert opts["tsize"] == to_string(byte_size(ctx.small_content))

      :gen_udp.close(socket)
    end
  end

  # --- TFTP client helpers ---

  defp tftp_read(host, port, filename) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    # Build RRQ: opcode 1 | filename | 0 | mode | 0
    packet = <<0, 1, filename::binary, 0, "octet", 0>>
    :ok = :gen_udp.send(socket, host, port, packet)

    result = receive_file(socket, 512)
    :gen_udp.close(socket)
    result
  end

  # Receive DATA packets from transfer worker, send ACKs, reassemble file.
  # The first response comes from the transfer worker's ephemeral port (not
  # the server's listening port) per RFC 1350 TID rules.
  defp receive_file(socket, block_size, transfer_port \\ nil, acc \\ <<>>) do
    case :gen_udp.recv(socket, 0, @recv_timeout) do
      {:ok, {addr, from_port, response}} ->
        # Track transfer port from first packet
        tp = transfer_port || from_port

        case Protocol.decode(response) do
          {:ok, {:data, block, data}} ->
            # ACK to the transfer worker port
            ack = Protocol.encode({:ack, block})
            :gen_udp.send(socket, addr, tp, ack)

            acc = <<acc::binary, data::binary>>

            if byte_size(data) < block_size do
              # Last block — transfer complete
              {:ok, acc}
            else
              receive_file(socket, block_size, tp, acc)
            end

          {:ok, {:error, code, msg}} ->
            {:error, code, msg}

          _other ->
            {:error, :unexpected_packet, "Unexpected response"}
        end

      {:error, :timeout} ->
        {:error, :timeout, "No response from TFTP server"}
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp safe_stop(_), do: :ok
end
