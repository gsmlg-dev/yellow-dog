defmodule YellowDog.DhcpClient.OSIntegration.HookNM do
  @moduledoc """
  NetworkManager hook-mode OS integration.

  For desktop environments where NetworkManager owns the interface. The DHCP client
  performs the handshake but delegates all IP/route/DNS configuration to NM.

  Lease data is reported to NetworkManager by:
  1. Writing a JSON lease file to `/tmp/yd-dhcp-{iface}.json` for NM dispatcher scripts.
  2. Optionally invoking `nmcli` to signal the new lease.

  Deconfigure, route, and DNS callbacks are no-ops since NetworkManager handles
  teardown and network stack configuration.
  """

  @behaviour YellowDog.DhcpClient.OSIntegration

  alias YellowDog.DhcpClient.Lease

  require Logger

  @lease_dir "/tmp"

  @impl true
  @spec apply_lease(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_lease(interface, %Lease{} = lease) do
    start = System.monotonic_time(:millisecond)

    result =
      with :ok <- write_lease_json(interface, lease),
           :ok <- notify_networkmanager(interface) do
        :ok
      end

    duration_ms = System.monotonic_time(:millisecond) - start
    status = if result == :ok, do: :ok, else: :error

    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :os, :apply],
      %{duration_ms: duration_ms},
      %{interface: interface, action: :configure, result: status}
    )

    result
  end

  @impl true
  @spec deconfigure(String.t()) :: :ok | {:error, term()}
  def deconfigure(interface) do
    # NetworkManager handles teardown; clean up our lease file
    _ = File.rm(lease_file_path(interface))

    Logger.debug("DHCP client hook: deconfigure no-op for #{interface} (NM handles teardown)")
    :ok
  end

  @impl true
  @spec apply_routes(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_routes(interface, _lease) do
    Logger.debug("DHCP client hook: apply_routes no-op for #{interface} (NM handles routes)")
    :ok
  end

  @impl true
  @spec apply_dns(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_dns(interface, _lease) do
    Logger.debug("DHCP client hook: apply_dns no-op for #{interface} (NM handles DNS)")
    :ok
  end

  # -- Private helpers -------------------------------------------------------

  defp write_lease_json(interface, %Lease{} = lease) do
    data = %{
      "interface" => interface,
      "ip" => format_ip(lease.ip),
      "subnet_mask" => format_ip(lease.subnet_mask),
      "prefix_length" => Lease.prefix_length(lease),
      "router" => format_ip_or_nil(lease.router),
      "dns_servers" => Enum.map(lease.dns_servers, &format_ip/1),
      "domain_name" => lease.domain_name,
      "lease_time" => lease.lease_time,
      "server_ip" => format_ip(lease.server_ip),
      "mtu" => lease.mtu,
      "ntp_servers" => Enum.map(lease.ntp_servers, &format_ip/1),
      "obtained_at" => DateTime.to_iso8601(lease.obtained_at),
      "yellowdog_server" => lease.yellowdog_server,
      "control_url" => lease.control_url
    }

    path = lease_file_path(interface)

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        Logger.warning(
          "DHCP client hook: failed to encode lease JSON for #{interface}: #{inspect(reason)}"
        )

        {:error, {:json_encode, reason}}
    end
  rescue
    UndefinedFunctionError ->
      # Jason not available; write a simple key=value fallback
      content = build_fallback_lease(interface, lease)
      File.write(lease_file_path(interface), content)
  end

  defp notify_networkmanager(interface) do
    try do
      case System.cmd("nmcli", ["device", "reapply", interface], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, _code} ->
          Logger.debug(
            "DHCP client hook: nmcli reapply returned non-zero for #{interface}: #{String.trim(output)}"
          )

          # Non-fatal: the lease JSON is written for dispatcher scripts regardless
          :ok
      end
    rescue
      e in ErlangError ->
        Logger.warning("DHCP client hook: nmcli not available: #{Exception.message(e)}")
        # Non-fatal: lease file is the primary mechanism
        :ok
    end
  end

  defp build_fallback_lease(interface, %Lease{} = lease) do
    lines = [
      "interface=#{interface}",
      "ip=#{format_ip(lease.ip)}",
      "subnet_mask=#{format_ip(lease.subnet_mask)}",
      "prefix_length=#{Lease.prefix_length(lease)}",
      "router=#{format_ip_or_nil(lease.router)}",
      "dns_servers=#{lease.dns_servers |> Enum.map(&format_ip/1) |> Enum.join(",")}",
      "domain_name=#{lease.domain_name || ""}",
      "lease_time=#{lease.lease_time}",
      "server_ip=#{format_ip(lease.server_ip)}",
      "obtained_at=#{DateTime.to_iso8601(lease.obtained_at)}"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp lease_file_path(interface) do
    Path.join(@lease_dir, "yd-dhcp-#{interface}.json")
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip_or_nil(nil), do: nil
  defp format_ip_or_nil(ip), do: format_ip(ip)
end
