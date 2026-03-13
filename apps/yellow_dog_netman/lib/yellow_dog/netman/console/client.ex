defmodule YellowDog.Netman.Console.Client do
  @moduledoc """
  WebSocket client that connects this Netman instance to a remote
  YellowDog Console for centralized management.

  Uses `phoenix_socket_client` to maintain a persistent WebSocket
  connection and pushes periodic status updates.

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
  @join_retry_interval 3_000
  @max_join_attempts 20

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
      config: config,
      status_interval: config[:status_interval] || @default_status_interval,
      connected: false,
      join_attempts: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case start_socket(state.config) do
      {:ok, socket} ->
        Logger.info("[Netman.Console.Client] Socket process started, waiting for connection...")
        Process.send_after(self(), :join_channel, @join_retry_interval)
        {:noreply, %{state | socket: socket, join_attempts: 0}}

      {:error, reason} ->
        Logger.warning("[Netman.Console.Client] Failed to start socket: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_info(:join_channel, %{socket: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:join_channel, %{join_attempts: attempts} = state)
      when attempts >= @max_join_attempts do
    Logger.warning(
      "[Netman.Console.Client] Max join attempts reached, restarting socket connection"
    )

    stop_socket(state.socket)
    Process.send_after(self(), :reconnect, 5_000)
    {:noreply, %{state | socket: nil, channel: nil, connected: false, join_attempts: 0}}
  end

  def handle_info(:join_channel, state) do
    if Phoenix.SocketClient.connected?(state.socket) do
      payload = build_status_payload()

      case Phoenix.SocketClient.Channel.join(state.socket, "netman:control", payload) do
        {:ok, _response, channel} ->
          Logger.info("[Netman.Console.Client] Joined netman:control channel")
          schedule_status_push(state.status_interval)
          {:noreply, %{state | channel: channel, connected: true}}

        {:error, reason} ->
          Logger.warning("[Netman.Console.Client] Channel join failed: #{inspect(reason)}")
          Process.send_after(self(), :join_channel, @join_retry_interval)
          {:noreply, %{state | join_attempts: state.join_attempts + 1}}
      end
    else
      Logger.debug("[Netman.Console.Client] Socket not connected yet, retrying...")
      Process.send_after(self(), :join_channel, @join_retry_interval)
      {:noreply, %{state | join_attempts: state.join_attempts + 1}}
    end
  end

  def handle_info(:push_status, %{channel: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:push_status, state) do
    payload = build_status_payload()

    case Phoenix.SocketClient.Channel.push(state.channel, "status", payload) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.debug("[Netman.Console.Client] Status push failed: #{inspect(reason)}")
    end

    schedule_status_push(state.status_interval)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(%Phoenix.SocketClient.Message{} = _msg, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket) do
    stop_socket(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private

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
      reconnect?: true,
      reconnect_interval: 10_000,
      heartbeat_interval: 30_000
    )
  end

  defp stop_socket(nil), do: :ok

  defp stop_socket(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

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

    YellowDog.Netman.list_interfaces()
    |> Enum.map(fn iface ->
      name = iface[:interface] || iface[:name] || iface[:ifname]

      addresses =
        try do
          AddressManager.get_addresses(to_string(name))
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
          RouteManager.get_routes(to_string(name))
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
  rescue
    _ -> []
  end

  defp list_connections do
    YellowDog.Netman.list_connections()
    |> Enum.map(fn conn ->
      %{
        "interface" => conn[:interface],
        "profile_id" => conn[:profile_id],
        "state" => to_string(conn[:state] || "unknown"),
        "ip" => format_conn_ip(conn)
      }
    end)
  rescue
    _ -> []
  end

  defp format_conn_ip(conn) do
    case conn[:lease] do
      %{ip: ip} when not is_nil(ip) -> format_ip(ip)
      _ -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: nil

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
    # Derive a stable node ID from the SSH host key or machine-id
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

  defp schedule_status_push(interval) do
    Process.send_after(self(), :push_status, interval)
  end
end
