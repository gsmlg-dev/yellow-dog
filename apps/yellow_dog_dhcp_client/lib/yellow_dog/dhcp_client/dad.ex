defmodule YellowDog.DhcpClient.DAD do
  @moduledoc """
  Duplicate Address Detection (DAD) per RFC 5227.

  Sends ARP probes via the socket process to verify that a offered IP address
  is not already in use on the network before the client configures it.

  Listens for `{:arp_rx, sender_ip, sender_mac}` messages. If a reply
  matching the target IP is received during the probe window, a conflict
  is reported.
  """

  alias YellowDog.DhcpClient.DhcpSocket

  @default_probes 3
  @default_wait_ms 2_000
  @probe_interval_ms 700

  @doc """
  Performs duplicate address detection for `ip`.

  Sends ARP probes through the socket at `socket_pid` and waits for
  potential conflict replies.

  ## Options

    * `:probes` - Number of ARP probes to send (default: 3)
    * `:wait_ms` - Total wait time in milliseconds (default: 2000)

  ## Returns

    * `:ok` - No conflict detected
    * `{:conflict, mac}` - Address is in use by the given MAC
  """
  @spec check(pid(), :inet.ip4_address(), keyword()) :: :ok | {:conflict, binary()}
  def check(socket_pid, ip, opts \\ []) do
    probes = Keyword.get(opts, :probes, @default_probes)
    wait_ms = Keyword.get(opts, :wait_ms, @default_wait_ms)

    emit_dad_start(ip)

    result = send_probes_and_listen(socket_pid, ip, probes, wait_ms)

    emit_dad_result(ip, result)

    result
  end

  defp send_probes_and_listen(socket_pid, ip, probes, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms

    Enum.each(0..(probes - 1), fn i ->
      if i > 0 do
        Process.sleep(@probe_interval_ms)
      end

      DhcpSocket.send_arp_probe(socket_pid, ip)
    end)

    await_conflict(ip, deadline)
  end

  defp await_conflict(ip, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :ok
    else
      receive do
        {:arp_rx, sender_ip, sender_mac} when sender_ip == ip ->
          {:conflict, sender_mac}

        {:arp_rx, _other_ip, _mac} ->
          await_conflict(ip, deadline)
      after
        remaining ->
          :ok
      end
    end
  end

  defp emit_dad_start(ip) do
    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :dad, :start],
      %{},
      %{ip: format_ip(ip)}
    )
  end

  defp emit_dad_result(ip, result) do
    conflict = match?({:conflict, _}, result)

    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :dad, :result],
      %{},
      %{ip: format_ip(ip), conflict: conflict}
    )
  end

  defp format_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp format_ip(ip), do: to_string(ip)
end
