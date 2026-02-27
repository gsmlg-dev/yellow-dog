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

    # Remove DNS configuration based on method
    dns_method = get_dns_method(interface)
    deconfigure_dns(dns_method, interface)

    # Clean up resolv.conf fragment (ignore errors — file may already be gone)
    resolv_path = Path.join(@resolv_dir, "resolv.conf.#{interface}")
    _ = File.rm(resolv_path)

    :ok
  end

  defp deconfigure_dns(:resolvconf, interface) do
    _ = timed_cmd(interface, :del_dns, "resolvconf", ["-d", interface])
    :ok
  end

  defp deconfigure_dns(:direct, _interface) do
    # With direct mode, we don't remove /etc/resolv.conf as other interfaces
    # may depend on it. The fragment file is cleaned up by the caller.
    :ok
  end

  defp deconfigure_dns(:systemd_resolved, interface) do
    _ = timed_cmd(interface, :del_dns, "resolvectl", ["revert", interface])
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
    servers = Enum.filter(servers, &is_tuple/1)

    if servers == [] do
      :ok
    else
      dns_method = get_dns_method(interface)
      apply_dns_method(dns_method, interface, servers, lease.domain_name)
    end
  end

  defp apply_dns_method(:resolvconf, interface, servers, domain_name) do
    content = build_resolv_conf(servers, domain_name)
    resolv_path = Path.join(@resolv_dir, "resolv.conf.#{interface}")

    with :ok <- File.mkdir_p(@resolv_dir),
         :ok <- File.write(resolv_path, content) do
      timed_cmd(interface, :add_dns, "sh", [
        "-c",
        "resolvconf -a \"$1\" < \"$2\"",
        "sh",
        interface,
        resolv_path
      ])
    end
  end

  defp apply_dns_method(:direct, interface, servers, domain_name) do
    content = build_resolv_conf(servers, domain_name)

    with :ok <- File.mkdir_p(@resolv_dir) do
      # Write interface-specific fragment for reference
      resolv_path = Path.join(@resolv_dir, "resolv.conf.#{interface}")
      _ = File.write(resolv_path, content)

      # Write directly to /etc/resolv.conf
      case File.write("/etc/resolv.conf", content) do
        :ok ->
          emit_telemetry(interface, :add_dns, :ok, 0)
          :ok

        {:error, reason} = error ->
          Logger.warning(
            "DHCP client OS integration failed: interface=#{interface} action=add_dns reason=#{inspect(reason)}"
          )

          emit_telemetry(interface, :add_dns, error, 0)
          error
      end
    end
  end

  defp apply_dns_method(:systemd_resolved, interface, servers, domain_name) do
    server_strs = Enum.map(servers, &format_ip/1)

    # Set DNS servers for the interface
    dns_result =
      timed_cmd(interface, :add_dns, "resolvectl", ["dns", interface | server_strs])

    # Optionally set search domain
    domain_result =
      case domain_name do
        nil ->
          :ok

        "" ->
          :ok

        domain ->
          timed_cmd(interface, :add_dns_domain, "resolvectl", ["domain", interface, domain])
      end

    case {dns_result, domain_result} do
      {:ok, :ok} -> :ok
      {{:error, _} = err, _} -> err
      {_, {:error, _} = err} -> err
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp get_dns_method(interface) do
    try do
      config = YellowDog.DhcpClient.Config.load(interface)
      config.standalone.dns_method
    rescue
      _ -> :resolvconf
    end
  end

  @min_mtu 68
  @max_mtu 65_535

  defp maybe_set_mtu(_interface, %Lease{mtu: nil}), do: :ok

  defp maybe_set_mtu(interface, %Lease{mtu: mtu})
       when is_integer(mtu) and mtu >= @min_mtu and mtu <= @max_mtu do
    timed_cmd(interface, :set_mtu, "ip", ["link", "set", interface, "mtu", Integer.to_string(mtu)])
  end

  defp maybe_set_mtu(interface, %Lease{mtu: mtu}) do
    Logger.warning(
      "DHCP client ignoring invalid MTU #{inspect(mtu)} for #{interface} (valid: #{@min_mtu}..#{@max_mtu})"
    )

    :ok
  end

  @doc false
  def build_resolv_conf(servers, domain_name) do
    lines =
      case domain_name do
        nil -> []
        "" -> []
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
