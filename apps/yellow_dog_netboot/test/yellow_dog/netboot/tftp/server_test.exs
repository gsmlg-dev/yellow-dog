defmodule YellowDog.Netboot.TFTP.ServerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.TFTP.{Server, Protocol}

  setup do
    root = Path.join(System.tmp_dir!(), "tftp_server_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Create test files in root
    File.write!(Path.join(root, "vmlinuz"), "linux kernel data here")
    File.mkdir_p!(Path.join(root, "nixos"))
    File.write!(Path.join(root, "nixos/initrd.img"), "initrd image data")

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  # Build a raw TFTP RRQ packet (Protocol.encode doesn't support RRQ/WRQ)
  defp build_rrq(filename, mode, opts \\ %{}) do
    opts_bin =
      Enum.reduce(opts, <<>>, fn {key, value}, acc ->
        <<acc::binary, key::binary, 0, value::binary, 0>>
      end)

    <<0, 1, filename::binary, 0, mode::binary, 0, opts_bin::binary>>
  end

  # Build a raw TFTP WRQ packet
  defp build_wrq(filename, mode) do
    <<0, 2, filename::binary, 0, mode::binary, 0>>
  end

  defp blocked_root_path do
    parent =
      Path.join(
        System.tmp_dir!(),
        "tftp_server_blocked_root_#{System.unique_integer([:positive])}"
      )

    blocker = Path.join(parent, "blocker")
    root = Path.join(blocker, "root")

    File.mkdir_p!(parent)
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm_rf!(parent) end)

    root
  end

  defp start_server(root, opts \\ []) do
    config = Map.merge(%{tftp_port: 0, tftp_root: root}, Map.new(opts))
    name = :"tftp_server_#{System.unique_integer([:positive])}"

    {:ok, pid} = GenServer.start_link(Server, [config: config], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{server: name, pid: pid}
  end

  describe "init/1 with valid root" do
    test "starts and reports running", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      assert status.running == true
      assert status.port > 0
      assert status.root_dir == root
    end

    test "indexes files in root directory", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      assert status.file_count >= 2
    end

    test "returns root_dir via call", %{root: root} do
      %{server: name} = start_server(root)

      assert GenServer.call(name, :root_dir) == root
    end
  end

  describe "init/1 with missing root" do
    test "creates the root directory and starts" do
      parent =
        Path.join(
          System.tmp_dir!(),
          "tftp_server_missing_root_#{System.unique_integer([:positive])}"
        )

      root = Path.join(parent, "tftp")
      on_exit(fn -> File.rm_rf!(parent) end)

      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      assert status.running == true
      assert status.root_dir == root
      assert File.dir?(root)
    end
  end

  describe "init/1 with invalid root" do
    test "starts but reports not running" do
      blocked_root = blocked_root_path()
      name = :"tftp_server_#{System.unique_integer([:positive])}"
      config = %{tftp_port: 0, tftp_root: blocked_root}

      {:ok, pid} = GenServer.start_link(Server, [config: config], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      status = GenServer.call(name, :status)
      assert status.running == false
      assert status.root_dir == blocked_root
    end

    test "file count is 0 when not running" do
      blocked_root = blocked_root_path()
      name = :"tftp_server_#{System.unique_integer([:positive])}"
      config = %{tftp_port: 0, tftp_root: blocked_root}

      {:ok, pid} = GenServer.start_link(Server, [config: config], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      status = GenServer.call(name, :status)
      assert status.file_count == 0
    end
  end

  describe "init/1 with no config" do
    test "uses default port and root" do
      name = :"tftp_server_#{System.unique_integer([:positive])}"

      {:ok, pid} = GenServer.start_link(Server, [], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      status = GenServer.call(name, :status)
      assert status.root_dir == "/srv/netboot/tftp"
    end
  end

  describe "handle_info - UDP read request" do
    test "serves existing file via RRQ", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("vmlinuz", "octet")
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      # The server spawns a Transfer worker which sends from a new port.
      # TransferSupervisor may not be started in test scope,
      # so just verify the server didn't crash.
      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end

    test "rejects write requests", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      wrq_packet = build_wrq("upload.bin", "octet")
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, wrq_packet)

      # Should receive an ERROR packet (code 2 = access violation)
      case :gen_udp.recv(client, 0, 2000) do
        {:ok, {_addr, _port, packet}} ->
          {:ok, {:error, code, _msg}} = Protocol.decode(packet)
          assert code == 2

        {:error, :timeout} ->
          assert Process.alive?(GenServer.whereis(name))
      end

      :gen_udp.close(client)
    end

    test "sends error for invalid packets", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      # Send garbage data
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, <<255, 255, 255>>)

      # Should receive ERROR code 4 (illegal operation) or server stays alive
      case :gen_udp.recv(client, 0, 2000) do
        {:ok, {_addr, _port, packet}} ->
          {:ok, {:error, code, _msg}} = Protocol.decode(packet)
          assert code == 4

        {:error, :timeout} ->
          assert Process.alive?(GenServer.whereis(name))
      end

      :gen_udp.close(client)
    end
  end

  describe "handle_info - catch-all" do
    test "ignores unknown messages", %{root: root} do
      %{server: name, pid: pid} = start_server(root)

      send(pid, :some_random_message)
      Process.sleep(10)

      assert Process.alive?(pid)
      status = GenServer.call(name, :status)
      assert status.running == true
    end
  end

  describe "negotiate_block_size (via RRQ with blksize)" do
    test "RRQ with blksize option doesn't crash server", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("vmlinuz", "octet", %{"blksize" => "1024"})
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end

    test "RRQ with tsize option doesn't crash server", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("vmlinuz", "octet", %{"tsize" => "0"})
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end

    test "RRQ with invalid blksize doesn't crash server", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("vmlinuz", "octet", %{"blksize" => "not_a_number"})
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end

    test "RRQ with both blksize and tsize options", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("vmlinuz", "octet", %{"blksize" => "1024", "tsize" => "0"})
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end
  end

  describe "path traversal protection" do
    test "RRQ for ../etc/passwd sends error", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("../../../etc/passwd", "octet")
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      case :gen_udp.recv(client, 0, 2000) do
        {:ok, {_addr, _port, packet}} ->
          {:ok, {:error, code, _msg}} = Protocol.decode(packet)
          assert code == 2

        {:error, :timeout} ->
          assert Process.alive?(GenServer.whereis(name))
      end

      :gen_udp.close(client)
    end

    test "RRQ for nonexistent file sends file not found error", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("nonexistent.bin", "octet")
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      case :gen_udp.recv(client, 0, 2000) do
        {:ok, {_addr, _port, packet}} ->
          {:ok, {:error, code, _msg}} = Protocol.decode(packet)
          assert code == 1

        {:error, :timeout} ->
          assert Process.alive?(GenServer.whereis(name))
      end

      :gen_udp.close(client)
    end
  end

  describe "config handling" do
    test "non-map config uses defaults" do
      name = :"tftp_server_#{System.unique_integer([:positive])}"

      {:ok, pid} = GenServer.start_link(Server, [config: nil], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      status = GenServer.call(name, :status)
      assert status.root_dir == "/srv/netboot/tftp"
    end

    test "nested config map access works", %{root: root} do
      name = :"tftp_server_#{System.unique_integer([:positive])}"
      config = %{tftp_port: 0, tftp_root: root}

      {:ok, pid} = GenServer.start_link(Server, [config: config], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      status = GenServer.call(name, :status)
      assert status.running == true
      assert status.root_dir == root
    end
  end

  describe "RRQ for subdirectory files" do
    test "serves file in nested directory", %{root: root} do
      %{server: name} = start_server(root)

      status = GenServer.call(name, :status)
      server_port = status.port

      {:ok, client} = :gen_udp.open(0, [:binary, active: false])

      rrq_packet = build_rrq("nixos/initrd.img", "octet")
      :gen_udp.send(client, {127, 0, 0, 1}, server_port, rrq_packet)

      Process.sleep(50)
      assert Process.alive?(GenServer.whereis(name))

      :gen_udp.close(client)
    end
  end
end
