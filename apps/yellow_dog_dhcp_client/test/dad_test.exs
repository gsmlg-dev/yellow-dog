defmodule YellowDog.DhcpClient.DADTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.DAD
  alias YellowDog.DhcpClient.DhcpSocket

  @target_ip {192, 168, 1, 50}
  @conflict_mac <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>

  # -- Mock socket implementation that records ARP probe calls --

  defmodule MockArpSocket do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.DhcpSocket

    @impl true
    def open(_interface, _owner) do
      {:ok, make_ref()}
    end

    @impl true
    def send_broadcast(_ref, _packet), do: :ok

    @impl true
    def send_unicast(_ref, _dest, _packet), do: :ok

    @impl true
    def send_arp_probe(ref, ip) do
      # Notify the test coordinator (stored in persistent_term) about the probe
      case :persistent_term.get({__MODULE__, ref}, nil) do
        nil -> :ok
        pid -> send(pid, {:arp_probe_sent, ip})
      end

      :ok
    end

    @impl true
    def close(ref) do
      :persistent_term.erase({__MODULE__, ref})
      :ok
    end
  end

  setup do
    {:ok, socket_pid} =
      DhcpSocket.start_link(
        interface: "test_dad0",
        owner: self(),
        impl: MockArpSocket
      )

    # Register the test process as the probe notification target.
    # We need to get the socket ref from the GenServer state. Since the
    # mock stores it on open, we track it via the socket_pid instead:
    # We'll register using the socket_pid as coordinator key.

    on_exit(fn ->
      try do
        if Process.alive?(socket_pid), do: GenServer.stop(socket_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{socket_pid: socket_pid}
  end

  # -- Tests --

  test "returns :ok when no ARP reply received", %{socket_pid: socket_pid} do
    # With a very short wait window and no replies, DAD should return :ok
    result = DAD.check(socket_pid, @target_ip, probes: 1, wait_ms: 100)
    assert result == :ok
  end

  test "returns {:conflict, mac} when ARP reply matches target IP", %{socket_pid: socket_pid} do
    target_ip = @target_ip
    conflict_mac = @conflict_mac

    # Spawn a task that runs DAD.check (it blocks on receive internally)
    task =
      Task.async(fn ->
        DAD.check(socket_pid, target_ip, probes: 1, wait_ms: 2000)
      end)

    # Give DAD time to send probes and enter await_conflict
    Process.sleep(50)

    # Send a matching ARP reply to the task process
    send(task.pid, {:arp_rx, target_ip, conflict_mac})

    result = Task.await(task, 3000)
    assert result == {:conflict, conflict_mac}
  end

  test "ignores ARP replies for non-matching IPs", %{socket_pid: socket_pid} do
    target_ip = @target_ip
    other_ip = {10, 0, 0, 99}

    task =
      Task.async(fn ->
        DAD.check(socket_pid, target_ip, probes: 1, wait_ms: 200)
      end)

    # Give DAD time to enter await_conflict
    Process.sleep(50)

    # Send an ARP reply for a different IP -- should be ignored
    send(task.pid, {:arp_rx, other_ip, @conflict_mac})

    result = Task.await(task, 1000)
    assert result == :ok
  end

  test "detects conflict even after ignoring non-matching reply", %{socket_pid: socket_pid} do
    target_ip = @target_ip
    other_ip = {10, 0, 0, 99}
    conflict_mac = @conflict_mac

    task =
      Task.async(fn ->
        DAD.check(socket_pid, target_ip, probes: 1, wait_ms: 2000)
      end)

    Process.sleep(50)

    # First send a non-matching reply, then a matching one
    send(task.pid, {:arp_rx, other_ip, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>})
    Process.sleep(10)
    send(task.pid, {:arp_rx, target_ip, conflict_mac})

    result = Task.await(task, 3000)
    assert result == {:conflict, conflict_mac}
  end

  test "respects custom probe count", %{socket_pid: socket_pid} do
    # We can verify the function completes with different probe counts.
    # With probes: 1 and short wait, it should be fast.
    result = DAD.check(socket_pid, @target_ip, probes: 1, wait_ms: 50)
    assert result == :ok

    # With probes: 2, it should still return :ok (no conflict), just takes longer
    # due to @probe_interval_ms between probes.
    result = DAD.check(socket_pid, @target_ip, probes: 2, wait_ms: 50)
    assert result == :ok
  end

  test "respects custom wait_ms — completes faster with shorter wait", %{socket_pid: socket_pid} do
    start = System.monotonic_time(:millisecond)
    DAD.check(socket_pid, @target_ip, probes: 1, wait_ms: 50)
    elapsed = System.monotonic_time(:millisecond) - start

    # Should complete in roughly 50ms (plus overhead), not the default 2000ms
    assert elapsed < 500
  end

  test "emits telemetry start and result events", %{socket_pid: socket_pid} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "dad-test-start-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :dad, :start],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "dad-test-result-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :dad, :result],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("dad-test-start-#{inspect(ref)}")
      :telemetry.detach("dad-test-result-#{inspect(ref)}")
    end)

    DAD.check(socket_pid, @target_ip, probes: 1, wait_ms: 50)

    assert_receive {:telemetry_event, [:yellow_dog, :dhcp_client, :dad, :start], %{},
                    %{ip: "192.168.1.50"}},
                   1000

    assert_receive {:telemetry_event, [:yellow_dog, :dhcp_client, :dad, :result], %{},
                    %{ip: "192.168.1.50", conflict: false}},
                   1000
  end

  test "emits telemetry result with conflict: true on conflict", %{socket_pid: socket_pid} do
    ref = make_ref()
    test_pid = self()
    target_ip = @target_ip
    conflict_mac = @conflict_mac

    :telemetry.attach(
      "dad-test-conflict-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :dad, :result],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("dad-test-conflict-#{inspect(ref)}")
    end)

    task =
      Task.async(fn ->
        DAD.check(socket_pid, target_ip, probes: 1, wait_ms: 2000)
      end)

    Process.sleep(50)
    send(task.pid, {:arp_rx, target_ip, conflict_mac})
    Task.await(task, 3000)

    assert_receive {:telemetry_event, [:yellow_dog, :dhcp_client, :dad, :result], %{},
                    %{ip: "192.168.1.50", conflict: true}},
                   1000
  end

  test "formats IPv4 tuple as string in telemetry metadata", %{socket_pid: socket_pid} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "dad-test-format-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :dad, :start],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ip_format, metadata.ip})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("dad-test-format-#{inspect(ref)}")
    end)

    DAD.check(socket_pid, {10, 0, 0, 1}, probes: 1, wait_ms: 50)

    assert_receive {:ip_format, "10.0.0.1"}, 1000
  end

  test "telemetry metadata omits :interface key when not provided", %{socket_pid: socket_pid} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "dad-test-no-iface-#{inspect(ref)}",
      [:yellow_dog, :dhcp_client, :dad, :start],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:dad_start_meta, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("dad-test-no-iface-#{inspect(ref)}") end)

    # Call without :interface keyword — interface defaults to nil
    DAD.check(socket_pid, @target_ip, probes: 1, wait_ms: 50)

    assert_receive {:dad_start_meta, meta}, 1000
    assert Map.has_key?(meta, :ip)
    refute Map.has_key?(meta, :interface)
  end
end
