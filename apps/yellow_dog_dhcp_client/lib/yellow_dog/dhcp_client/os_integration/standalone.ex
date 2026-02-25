defmodule YellowDog.DhcpClient.OSIntegration.Standalone do
  @moduledoc """
  Standalone OS integration using `ip` commands via `System.cmd/3`.

  For headless and server environments where the DHCP client is the primary
  network owner. Directly assigns IP addresses, manages routes, and configures
  DNS resolvers on the interface.

  Requires `CAP_NET_ADMIN` on the BEAM process (typically granted via systemd
  `AmbientCapabilities`).

  All operations emit telemetry events under `[:yellow_dog, :dhcp_client, :os, :apply]`.
  """

  @behaviour YellowDog.DhcpClient.OSIntegration

  alias YellowDog.DhcpClient.Lease

  require Logger

  @resolv_dir "/run/yellowdog"

  @impl true
  @spec apply_lease(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_lease(interface, %Lease{} = lease) do
    ip_str = format_ip(lease.ip)
    prefix = Lease.prefix_length(lease)

    with :ok <-
           timed_cmd(interface, :add_addr, "ip", [
             "addr",
             "add",
             "#{ip_str}/#{prefix}",
             "dev",
             interface
           ]),
         :ok <- timed_cmd(interface, :link_up, "ip", ["link", "set", interface, "up"]),
         :ok <- maybe_set_mtu(interface, lease),
         :ok <- apply_routes(interface, lease),
         :ok <- apply_dns(interface, lease) do
      :ok
    end
  end

  @impl true
  @spec deconfigure(String.t()) :: :ok | {:error, term()}
  def deconfigure(interface) do
    # Flush all addresses from the interface
    _ = timed_cmd(interface, :flush_addr, "ip", ["addr", "flush", "dev", interface])

    # Remove default route through this interface
    _ = timed_cmd(interface, :del_route, "ip", ["route", "del", "default", "dev", interface])

    # Remove DNS configuration
    _ = timed_cmd(interface, :del_dns, "resolvconf", ["-d", interface])

    # Clean up resolv.conf fragment (ignore errors — file may already be gone)
    resolv_path = Path.join(@resolv_dir, "resolv.conf.#{interface}")
    _ = File.rm(resolv_path)

    :ok
  end

  @impl true
  @spec apply_routes(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_routes(interface, %Lease{router: nil}),
    do: log_skip(interface, :routes, "no router in lease")

  def apply_routes(interface, %Lease{router: router}) do
    router_str = format_ip(router)

    timed_cmd(interface, :add_route, "ip", [
      "route",
      "add",
      "default",
      "via",
      router_str,
      "dev",
      interface
    ])
  end

  @impl true
  @spec apply_dns(String.t(), Lease.t()) :: :ok | {:error, term()}
  def apply_dns(_interface, %Lease{dns_servers: []}), do: :ok

  def apply_dns(interface, %Lease{dns_servers: servers} = lease) do
    content = build_resolv_conf(servers, lease.domain_name)
    resolv_path = Path.join(@resolv_dir, "resolv.conf.#{interface}")

    with :ok <- File.mkdir_p(@resolv_dir),
         :ok <- File.write(resolv_path, content) do
      # resolvconf reads from stdin; use sh -c with positional args to pipe the
      # file safely without shell injection ($1=interface, $2=resolv_path).
      timed_cmd(interface, :add_dns, "sh", [
        "-c",
        "resolvconf -a \"$1\" < \"$2\"",
        "sh",
        interface,
        resolv_path
      ])
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp maybe_set_mtu(_interface, %Lease{mtu: nil}), do: :ok

  defp maybe_set_mtu(interface, %Lease{mtu: mtu}) when is_integer(mtu) and mtu > 0 do
    timed_cmd(interface, :set_mtu, "ip", ["link", "set", interface, "mtu", Integer.to_string(mtu)])
  end

  defp maybe_set_mtu(_interface, _lease), do: :ok

  defp build_resolv_conf(servers, domain_name) do
    lines =
      case domain_name do
        nil -> []
        domain -> ["search #{domain}"]
      end

    nameserver_lines =
      Enum.map(servers, fn server ->
        "nameserver #{format_ip(server)}"
      end)

    Enum.join(lines ++ nameserver_lines, "\n") <> "\n"
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp timed_cmd(interface, action, cmd, args) do
    start = System.monotonic_time(:millisecond)

    result =
      try do
        case System.cmd(cmd, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, code} -> {:error, {cmd, args, code, String.trim(output)}}
        end
      rescue
        e in ErlangError ->
          {:error, {:cmd_failed, cmd, Exception.message(e)}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start

    emit_telemetry(interface, action, result, duration_ms)

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "DHCP client OS integration failed: interface=#{interface} action=#{action} reason=#{inspect(reason)}"
        )

        error
    end
  end

  defp emit_telemetry(interface, action, result, duration_ms) do
    status = if result == :ok, do: :ok, else: :error

    :telemetry.execute(
      [:yellow_dog, :dhcp_client, :os, :apply],
      %{duration_ms: duration_ms},
      %{interface: interface, action: action, result: status}
    )
  end

  defp log_skip(interface, what, reason) do
    Logger.debug("DHCP client skipping #{what} for #{interface}: #{reason}")
    :ok
  end
end
