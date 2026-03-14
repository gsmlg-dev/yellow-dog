defmodule YellowDog.Netman.Console.Client do
  @moduledoc """
  WebSocket client that connects this Netman instance to a remote
  YellowDog Console for centralized management.

  Uses `phoenix_socket_client` to maintain a persistent WebSocket
  connection and pushes periodic status updates.

  ## Connection lifecycle

  The socket library handles WebSocket transport and reconnection.
  This GenServer manages channel join/rejoin with exponential backoff.

  ## Configuration

      config :yellow_dog_netman, :console,
        url: "ws://localhost:4270/netman/ws/websocket",
        token: "my-token",
        node_id: "node-1",
        hostname: "router-1",
        status_interval: 30_000

  Set `enabled: false` to disable (default in test).
  """

  use GenServer

  require Logger

  @default_status_interval 30_000
  @initial_check_interval 3_000
  @max_check_interval 30_000
  @telemetry_id {__MODULE__, :resolved_queries}
  @socket_name __MODULE__.Socket

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns whether the console connection is active."
  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_opts) do
    config = console_config()

    state = %{
      socket: nil,
      channel: nil,
      channel_ref: nil,
      config: config,
      status_interval: config[:status_interval] || @default_status_interval,
      connected: false,
      check_interval: @initial_check_interval
    }

    attach_telemetry()
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case start_socket(state.config) do
      {:ok, socket} ->
        Logger.info("[Netman.Console.Client] Socket started, waiting for connection...")
        schedule_connection_check(@initial_check_interval)
        {:noreply, %{state | socket: socket, check_interval: @initial_check_interval}}

      {:error, {:already_started, pid}} ->
        Logger.info("[Netman.Console.Client] Socket already running, reusing")
        schedule_connection_check(@initial_check_interval)
        {:noreply, %{state | socket: pid, check_interval: @initial_check_interval}}

      {:error, reason} ->
        Logger.warning("[Netman.Console.Client] Failed to start socket: #{inspect(reason)}")
        Process.send_after(self(), :restart_socket, 10_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  # -- Connection check with backoff --

  @impl true
  def handle_info(:check_connection, %{socket: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:check_connection, state) do
    socket_up = socket_connected?(state.socket)
    channel_up = state.channel != nil and Process.alive?(state.channel)

    {state, next_interval} =
      cond do
        socket_up and channel_up ->
          # Healthy — reset backoff
          {state, @max_check_interval}

        socket_up and not channel_up ->
          # Socket connected but no channel — try to join
          new_state = try_join_channel(state)

          if new_state.connected do
            # Join succeeded — reset backoff
            {new_state, @max_check_interval}
          else
            # Join failed — increase backoff
            {new_state, backoff(state.check_interval)}
          end

        true ->
          # Socket not connected — library will reconnect, just wait
          if state.connected do
            Logger.info("[Netman.Console.Client] Socket disconnected, waiting for reconnect...")
          end

          {%{state | channel: nil, channel_ref: nil, connected: false},
           backoff(state.check_interval)}
      end

    schedule_connection_check(next_interval)
    {:noreply, %{state | check_interval: next_interval}}
  end

  # -- Status push --

  def handle_info(:push_status, %{channel: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:push_status, state) do
    if state.channel && Process.alive?(state.channel) do
      payload = build_status_payload()
      Phoenix.SocketClient.Channel.push_async(state.channel, "status", payload)
    end

    schedule_status_push(state.status_interval)
    {:noreply, state}
  end

  # -- Real-time query log --

  def handle_info({:resolved_query, _entry}, %{channel: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:resolved_query, entry}, state) do
    if state.channel && Process.alive?(state.channel) do
      payload = %{
        "timestamp" => format_datetime(entry.timestamp),
        "domain" => entry.domain,
        "type" => to_string(entry.type),
        "source" => to_string(entry.source),
        "duration_us" => entry.duration_us,
        "error" => entry[:error]
      }

      Phoenix.SocketClient.Channel.push_async(state.channel, "query_log", payload)
    end

    {:noreply, state}
  end

  # -- Channel death detection --

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state) do
    Logger.info("[Netman.Console.Client] Channel ended, will rejoin on next check")
    {:noreply, %{state | channel: nil, channel_ref: nil, connected: false}}
  end

  # -- Socket restart (only used when start_socket fails initially) --

  def handle_info(:restart_socket, state) do
    if state.socket, do: stop_socket(state.socket)

    {:noreply, %{state | socket: nil, channel: nil, channel_ref: nil, connected: false},
     {:continue, :connect}}
  end

  def handle_info(%Phoenix.SocketClient.Message{} = _msg, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    detach_telemetry()
    if state[:socket], do: stop_socket(state.socket)
    :ok
  end

  # -- Private: channel join --

  defp try_join_channel(state) do
    payload = build_status_payload()

    case Phoenix.SocketClient.Channel.join(state.socket, "netman:control", payload) do
      {:ok, _response, channel} ->
        Logger.info("[Netman.Console.Client] Joined netman:control channel")
        ref = Process.monitor(channel)
        schedule_status_push(state.status_interval)
        %{state | channel: channel, channel_ref: ref, connected: true}

      {:error, {:already_started, _}} ->
        # Channel process exists but we lost our reference — find it
        Logger.debug("[Netman.Console.Client] Channel already started, reusing")
        state

      {:error, reason} ->
        Logger.debug("[Netman.Console.Client] Channel join failed: #{inspect(reason)}")
        state
    end
  catch
    :exit, _ ->
      Logger.debug("[Netman.Console.Client] Channel join exited")
      state
  end

  defp socket_connected?(socket) do
    Process.alive?(socket) and Phoenix.SocketClient.connected?(socket)
  catch
    :exit, _ -> false
  end

  defp backoff(current) do
    min(current * 2, @max_check_interval)
  end

  # -- Private: config & socket management --

  defp console_config do
    Application.get_env(:yellow_dog_netman, :console, [])
  end

  defp start_socket(config) do
    url = Keyword.fetch!(config, :url)
    token = Keyword.get(config, :token, "")
    node_id = Keyword.get(config, :node_id, node_id())
    hostname = Keyword.get(config, :hostname, hostname())
    version = Keyword.get(config, :version, version())

    params = %{
      "token" => token,
      "node_id" => node_id,
      "hostname" => hostname,
      "version" => version
    }

    Phoenix.SocketClient.start_link(
      url: url,
      params: params,
      name: @socket_name,
      reconnect?: true,
      reconnect_interval: 10_000,
      heartbeat_interval: 30_000
    )
  end

  defp stop_socket(nil), do: :ok

  defp stop_socket(pid) do
    if Process.alive?(pid) do
      Supervisor.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _ -> :ok
  end

  # -- Payload builders --

  defp build_status_payload do
    %{
      "ip" => local_ip(),
      "interfaces" => list_interfaces(),
      "connections" => list_connections(),
      "default_route" => default_route(),
      "resolved" => resolved_status()
    }
  end

  defp list_interfaces do
    alias YellowDog.Netman.Kernel.{AddressManager, RouteManager}

    case YellowDog.Netman.list_interfaces() do
      [] -> list_interfaces_fallback()
      ifaces -> enrich_interfaces(ifaces, AddressManager, RouteManager)
    end
  rescue
    _ -> []
  end

  defp enrich_interfaces(ifaces, address_manager, route_manager) do
    Enum.map(ifaces, fn iface ->
      name = iface[:interface] || iface[:name] || iface[:ifname]

      addresses =
        try do
          address_manager.get_addresses(to_string(name))
          |> Enum.map(fn addr ->
            %{
              "address" => addr[:address],
              "prefix_len" => addr[:prefix_len],
              "family" => to_string(addr[:family] || "unknown"),
              "scope" => to_string(addr[:scope] || "unknown")
            }
          end)
        rescue
          _ -> []
        end

      routes =
        try do
          route_manager.get_routes(to_string(name))
          |> Enum.map(fn route ->
            %{
              "destination" => route[:destination],
              "gateway" => route[:gateway],
              "metric" => route[:metric],
              "protocol" => route[:protocol],
              "family" => to_string(route[:family] || "unknown")
            }
          end)
        rescue
          _ -> []
        end

      %{
        "name" => to_string(name),
        "state" => to_string(iface[:state] || "unknown"),
        "carrier" => iface[:carrier],
        "mtu" => iface[:mtu],
        "mac" => iface[:mac],
        "kind" => iface[:kind],
        "index" => iface[:index],
        "addresses" => addresses,
        "routes" => routes
      }
    end)
  end

  defp list_interfaces_fallback do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.group_by(fn {name, _} -> to_string(name) end, fn {_, flags} -> flags end)
        |> Enum.with_index()
        |> Enum.map(fn {{name, flag_groups}, idx} ->
          flags = List.flatten(flag_groups)
          iface_flags = flags |> Keyword.get_values(:flags) |> List.flatten()

          addresses =
            flags
            |> extract_addresses()
            |> Enum.map(fn {addr_str, family} ->
              %{
                "address" => addr_str,
                "prefix_len" => prefix_len_from_flags(flags, family),
                "family" => to_string(family),
                "scope" => "unknown"
              }
            end)

          hwaddr = Keyword.get(flags, :hwaddr)

          mac =
            if hwaddr && length(hwaddr) == 6 do
              hwaddr
              |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
            end

          %{
            "name" => name,
            "state" => if(:up in iface_flags, do: "up", else: "down"),
            "carrier" => :running in iface_flags,
            "mtu" => nil,
            "mac" => mac,
            "kind" => nil,
            "index" => idx,
            "addresses" => addresses,
            "routes" => []
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp extract_addresses(flags) do
    flags
    |> Keyword.get_values(:addr)
    |> Enum.flat_map(fn addr ->
      case addr do
        {_, _, _, _} = ip4 -> [{ip4 |> :inet.ntoa() |> to_string(), :inet}]
        {_, _, _, _, _, _, _, _} = ip6 -> [{ip6 |> :inet.ntoa() |> to_string(), :inet6}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp prefix_len_from_flags(flags, :inet) do
    case Keyword.get(flags, :netmask) do
      {a, b, c, d} ->
        <<bits::32>> = <<a, b, c, d>>
        count_leading_ones(bits, 32)

      _ ->
        24
    end
  end

  defp prefix_len_from_flags(flags, :inet6) do
    case Keyword.get(flags, :netmask) do
      {a, b, c, d, e, f, g, h} ->
        <<bits::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
        count_leading_ones(bits, 128)

      _ ->
        64
    end
  end

  defp prefix_len_from_flags(_, _), do: 0

  defp count_leading_ones(bits, size) do
    binary = <<bits::size(size)>>
    count_ones(binary, 0)
  end

  defp count_ones(<<1::1, rest::bitstring>>, acc), do: count_ones(rest, acc + 1)
  defp count_ones(_, acc), do: acc

  defp list_connections do
    YellowDog.Netman.list_connections()
    |> Enum.map(fn conn ->
      lease = conn[:lease]

      lease_info =
        if lease && lease.ip do
          %{
            "ip" => format_ip(lease.ip),
            "subnet_mask" => format_ip(lease.subnet_mask),
            "gateway" => format_ip(lease.router),
            "dns_servers" => Enum.map(lease.dns_servers || [], &format_ip/1),
            "domain_name" => lease.domain_name,
            "lease_time" => lease.lease_time,
            "obtained_at" => format_datetime(lease.obtained_at),
            "expires_at" => format_datetime(YellowDog.DhcpClient.Lease.expires_at(lease)),
            "time_remaining" => YellowDog.DhcpClient.Lease.time_remaining(lease),
            "server_ip" => format_ip(lease.server_ip)
          }
        end

      %{
        "interface" => conn[:interface],
        "profile_id" => conn[:profile_id],
        "state" => to_string(conn[:state] || "unknown"),
        "ip" => format_conn_ip(lease),
        "lease" => lease_info
      }
    end)
  rescue
    _ -> []
  end

  defp format_conn_ip(%{ip: ip}) when not is_nil(ip), do: format_ip(ip)
  defp format_conn_ip(_), do: nil

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: nil

  defp resolved_status do
    if Code.ensure_loaded?(YellowDog.Resolved) and
         function_exported?(YellowDog.Resolved, :status, 0) do
      status = apply(YellowDog.Resolved, :status, [])

      query_log =
        if function_exported?(YellowDog.Resolved, :recent_queries, 1) do
          apply(YellowDog.Resolved, :recent_queries, [100])
          |> Enum.map(fn entry ->
            %{
              "timestamp" => format_datetime(entry.timestamp),
              "domain" => entry.domain,
              "type" => to_string(entry.type),
              "source" => to_string(entry.source),
              "duration_us" => entry.duration_us,
              "error" => entry[:error]
            }
          end)
        else
          []
        end

      %{
        "listen" => status.config.listen |> :inet.ntoa() |> to_string(),
        "port" => status.config.port,
        "upstreams" =>
          Enum.map(status.config.upstreams || [], fn ip ->
            ip |> :inet.ntoa() |> to_string()
          end),
        "cache_enabled" => status.config.cache_enabled,
        "counters" => %{
          "total" => status.counters.total,
          "cached" => status.counters.cached,
          "forwarded" => status.counters.forwarded,
          "intercepted" => status.counters.intercepted,
          "error" => status.counters.error
        },
        "query_log" => query_log
      }
    end
  rescue
    _ -> nil
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(_), do: nil

  defp default_route do
    case YellowDog.Netman.default_route() do
      {:ok, route} -> route
      :none -> nil
    end
  rescue
    _ -> nil
  end

  defp local_ip do
    case :inet.getif() do
      {:ok, [{ip, _, _} | _]} -> ip |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp node_id do
    hostname() <> "-" <> host_key_hash()
  end

  defp host_key_hash do
    key_material =
      read_ssh_host_key() ||
        read_machine_id() ||
        hostname()

    :crypto.hash(:sha256, key_material)
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  defp read_ssh_host_key do
    paths = [
      "/etc/ssh/ssh_host_ed25519_key.pub",
      "/etc/ssh/ssh_host_rsa_key.pub",
      "/etc/ssh/ssh_host_ecdsa_key.pub"
    ]

    Enum.find_value(paths, fn path ->
      case File.read(path) do
        {:ok, content} when byte_size(content) > 0 -> content
        _ -> nil
      end
    end)
  end

  defp read_machine_id do
    case File.read("/etc/machine-id") do
      {:ok, content} when byte_size(content) > 0 -> String.trim(content)
      _ -> nil
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp version do
    case :application.get_key(:yellow_dog_netman, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "0.1.0"
    end
  end

  # -- Telemetry --

  defp attach_telemetry do
    detach_telemetry()

    :telemetry.attach(
      @telemetry_id,
      [:yellow_dog, :resolved, :query, :stop],
      fn _event, measurements, metadata, config ->
        entry = %{
          timestamp: DateTime.utc_now(),
          domain: metadata.domain,
          type: metadata.type,
          source: metadata.source,
          duration_us:
            System.convert_time_unit(measurements[:duration] || 0, :native, :microsecond)
        }

        send(config.pid, {:resolved_query, entry})
      end,
      %{pid: self()}
    )
  rescue
    _ -> :ok
  end

  defp detach_telemetry do
    :telemetry.detach(@telemetry_id)
  rescue
    _ -> :ok
  end

  # -- Scheduling --

  defp schedule_status_push(interval) do
    Process.send_after(self(), :push_status, interval)
  end

  defp schedule_connection_check(interval) do
    Process.send_after(self(), :check_connection, interval)
  end
end
