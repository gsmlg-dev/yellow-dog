defmodule YellowDog.Netman.API.CLI do
  @moduledoc """
  JSON-RPC server over Unix domain socket for CLI communication.

  Accepts connections on `/run/yellowdog/netman.sock` (configurable),
  reads JSON commands, dispatches to the appropriate handler, and
  returns JSON responses.
  """

  use GenServer

  require Logger

  @default_socket_path "/run/yellowdog/netman.sock"
  @max_concurrent_clients 100
  @client_recv_timeout_ms 5_000
  @monitor_keepalive_ms 30_000

  defstruct [:socket_path, :listen_socket, active_clients: 0]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    socket_path =
      Application.get_env(:yellow_dog_netman, :socket_path, @default_socket_path)

    # Ensure socket directory exists
    socket_dir = Path.dirname(socket_path)

    case File.mkdir_p(socket_dir) do
      :ok -> :ok
      {:error, :eacces} -> Logger.warning("Cannot create socket directory: #{socket_dir}")
      {:error, reason} -> Logger.warning("Socket dir error: #{inspect(reason)}")
    end

    # Remove stale socket
    File.rm(socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           active: false,
           ifaddr: {:local, String.to_charlist(socket_path)}
         ]) do
      {:ok, listen_socket} ->
        # Accept connections asynchronously
        Process.send_after(self(), :accept, 0)

        {:ok,
         %__MODULE__{
           socket_path: socket_path,
           listen_socket: listen_socket
         }}

      {:error, reason} ->
        Logger.warning("Failed to start CLI socket: #{inspect(reason)}")
        {:ok, %__MODULE__{socket_path: socket_path}}
    end
  end

  @impl true
  def handle_info(:accept, %{listen_socket: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:accept, %{active_clients: n} = state) when n >= @max_concurrent_clients do
    Logger.warning("CLI connection limit reached (#{@max_concurrent_clients}), delaying accept")
    Process.send_after(self(), :accept, 1000)
    {:noreply, state}
  end

  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 100) do
      {:ok, client} ->
        cli_pid = self()

        Task.start(fn ->
          try do
            handle_client(client)
          after
            send(cli_pid, :client_done)
          end
        end)

        Process.send_after(self(), :accept, 0)
        {:noreply, %{state | active_clients: state.active_clients + 1}}

      {:error, :timeout} ->
        Process.send_after(self(), :accept, 100)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("CLI accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1000)
        {:noreply, state}
    end
  end

  def handle_info(:client_done, state) do
    {:noreply, %{state | active_clients: max(state.active_clients - 1, 0)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    File.rm(state.socket_path)
  end

  ## Command handling

  defp handle_client(socket) do
    case :gen_tcp.recv(socket, 0, @client_recv_timeout_ms) do
      {:ok, data} ->
        case data |> String.trim() |> Jason.decode() do
          {:ok, %{"method" => "monitor"}} ->
            handle_monitor(socket)

          {:ok, command} ->
            response = handle_command(command)
            :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
            :gen_tcp.close(socket)

          {:error, _} ->
            :gen_tcp.send(socket, Jason.encode!(%{"error" => "invalid JSON"}) <> "\n")
            :gen_tcp.close(socket)
        end

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  @doc false
  @monitor_events [
    [:yellow_dog, :netman, :connection, :state_change],
    [:yellow_dog, :netman, :reconciliation, :stop],
    [:yellow_dog, :netman, :kernel, :link_change],
    [:yellow_dog, :netman, :kernel, :address_change],
    [:yellow_dog, :netman, :kernel, :route_change],
    [:yellow_dog, :netman, :policy, :default_route_change]
  ]

  defp handle_monitor(socket) do
    pid = self()
    handler_id = {__MODULE__, :monitor, pid}

    :telemetry.attach_many(
      handler_id,
      @monitor_events,
      fn event_name, measurements, metadata, _config ->
        send(pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    :gen_tcp.send(socket, Jason.encode!(%{"event" => "monitor_started"}) <> "\n")
    result = monitor_loop(socket)
    :telemetry.detach(handler_id)
    result
  end

  defp monitor_loop(socket) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        event = %{
          "event" => Enum.join(event_name, "."),
          "measurements" => stringify_map(measurements),
          "metadata" => stringify_map(metadata),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case :gen_tcp.send(socket, Jason.encode!(event) <> "\n") do
          :ok -> monitor_loop(socket)
          {:error, _} -> :ok
        end
    after
      @monitor_keepalive_ms ->
        case :gen_tcp.send(socket, Jason.encode!(%{"event" => "keepalive"}) <> "\n") do
          :ok -> monitor_loop(socket)
          {:error, _} -> :ok
        end
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_atom(v), do: to_string(v)
  defp stringify_value(v) when is_tuple(v), do: inspect(v)
  defp stringify_value(v), do: v

  def handle_command(%{"method" => "status"}) do
    status = YellowDog.Netman.status()
    %{"result" => format_system_status(status)}
  end

  def handle_command(%{"method" => "device"}) do
    handle_command(%{"method" => "device.list"})
  end

  def handle_command(%{"method" => "device.list"}) do
    devices = YellowDog.Netman.list_interfaces()
    %{"result" => devices}
  end

  def handle_command(%{"method" => "device.show", "params" => %{"interface" => iface}}) do
    case validate_identifier(iface, 15) do
      :ok ->
        case YellowDog.Netman.interface_info(iface) do
          {:ok, info} -> %{"result" => info}
          {:error, :not_found} -> %{"error" => "interface not found"}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => "connection"}) do
    handle_command(%{"method" => "connection.list"})
  end

  def handle_command(%{"method" => "connection.list"}) do
    profiles = YellowDog.Netman.list_profiles()
    %{"result" => Enum.map(profiles, &format_profile/1)}
  end

  def handle_command(%{"method" => "connection.show", "params" => %{"id" => id}}) do
    case validate_identifier(id) do
      :ok ->
        case YellowDog.Netman.get_profile(id) do
          {:ok, profile} -> %{"result" => format_profile(profile)}
          {:error, :not_found} -> %{"error" => "profile not found"}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => "connection.up", "params" => %{"id" => id}}) do
    case validate_identifier(id) do
      :ok ->
        case YellowDog.Netman.activate(id) do
          :ok -> %{"result" => "activated"}
          {:error, reason} -> %{"error" => inspect(reason)}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => "connection.down", "params" => %{"id" => id}}) do
    case validate_identifier(id) do
      :ok ->
        case YellowDog.Netman.deactivate(id) do
          :ok -> %{"result" => "deactivated"}
          {:error, reason} -> %{"error" => inspect(reason)}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => "connection.add", "params" => %{"file" => path}}) do
    case validate_profile_path(path) do
      :ok ->
        case YellowDog.Netman.import_profile(path) do
          {:ok, profile} -> %{"result" => "imported: #{profile.id}"}
          {:error, reason} -> %{"error" => inspect(reason)}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => "connection.delete", "params" => %{"id" => id}}) do
    case validate_identifier(id) do
      :ok ->
        case YellowDog.Netman.delete_profile(id) do
          :ok -> %{"result" => "deleted"}
          {:error, reason} -> %{"error" => inspect(reason)}
        end

      {:error, reason} ->
        %{"error" => reason}
    end
  end

  def handle_command(%{"method" => method})
      when method in ["connection.up", "connection.down", "connection.delete"] do
    %{"error" => "#{method} requires 'id' parameter"}
  end

  def handle_command(%{"method" => "connection.add"}) do
    %{"error" => "connection.add requires 'file' parameter"}
  end

  def handle_command(%{"method" => method}) do
    %{"error" => "unknown method: #{method}"}
  end

  def handle_command(_) do
    %{"error" => "invalid command format"}
  end

  @max_id_length 128
  @id_pattern ~r/^[a-zA-Z0-9_\-\.]+$/

  defp validate_identifier(id, max_len \\ @max_id_length) do
    cond do
      not is_binary(id) -> {:error, "invalid identifier"}
      byte_size(id) == 0 -> {:error, "identifier cannot be empty"}
      byte_size(id) > max_len -> {:error, "identifier too long"}
      not Regex.match?(@id_pattern, id) -> {:error, "identifier contains invalid characters"}
      true -> :ok
    end
  end

  defp validate_profile_path(path) do
    cond do
      not is_binary(path) ->
        {:error, "invalid path"}

      byte_size(path) > 4096 ->
        {:error, "path too long"}

      String.contains?(path, "\0") ->
        {:error, "path contains null byte"}

      Path.extname(path) != ".toml" ->
        {:error, "profile must be a .toml file"}

      true ->
        expanded = Path.expand(path)

        cond do
          not File.regular?(expanded) ->
            {:error, "file not found"}

          match?({:ok, _}, File.read_link(expanded)) ->
            {:error, "symlinks are not allowed"}

          true ->
            :ok
        end
    end
  end

  defp format_system_status(status) do
    %{
      "running" => status.running,
      "interfaces" => length(status.interfaces),
      "connections" => length(status.connections),
      "default_route" =>
        case status.default_route do
          {:ok, id} -> id
          :none -> nil
        end
    }
  end

  defp format_profile(profile) do
    %{
      "id" => profile.id,
      "type" => to_string(profile.type),
      "interface" => profile.interface,
      "autoconnect" => profile.autoconnect,
      "priority" => profile.autoconnect_priority,
      "ipv4_method" => to_string(profile.ipv4.method),
      "ipv6_method" => to_string(profile.ipv6.method)
    }
  end
end
