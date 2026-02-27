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

  defstruct [:socket_path, :listen_socket, clients: []]

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
      {:error, :eacces} -> Logger.info("Cannot create socket directory: #{socket_dir}")
      {:error, reason} -> Logger.warning("Socket dir error: #{inspect(reason)}")
    end

    # Remove stale socket
    File.rm(socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true
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

  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 100) do
      {:ok, client} ->
        Task.start(fn -> handle_client(client) end)
        Process.send_after(self(), :accept, 0)
        {:noreply, state}

      {:error, :timeout} ->
        Process.send_after(self(), :accept, 100)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("CLI accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1000)
        {:noreply, state}
    end
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
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        response =
          data
          |> String.trim()
          |> Jason.decode()
          |> case do
            {:ok, command} -> handle_command(command)
            {:error, _} -> %{"error" => "invalid JSON"}
          end

        :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  @doc false
  def handle_command(%{"method" => "status"}) do
    status = YellowDog.Netman.status()
    %{"result" => format_system_status(status)}
  end

  def handle_command(%{"method" => "device.list"}) do
    devices = YellowDog.Netman.list_interfaces()
    %{"result" => devices}
  end

  def handle_command(%{"method" => "device.show", "params" => %{"interface" => iface}}) do
    case YellowDog.Netman.interface_info(iface) do
      {:ok, info} -> %{"result" => info}
      {:error, :not_found} -> %{"error" => "interface not found: #{iface}"}
    end
  end

  def handle_command(%{"method" => "connection.list"}) do
    profiles = YellowDog.Netman.list_profiles()
    %{"result" => Enum.map(profiles, &format_profile/1)}
  end

  def handle_command(%{"method" => "connection.show", "params" => %{"id" => id}}) do
    case YellowDog.Netman.get_profile(id) do
      {:ok, profile} -> %{"result" => format_profile(profile)}
      {:error, :not_found} -> %{"error" => "profile not found: #{id}"}
    end
  end

  def handle_command(%{"method" => "connection.up", "params" => %{"id" => id}}) do
    case YellowDog.Netman.activate(id) do
      :ok -> %{"result" => "activated"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  def handle_command(%{"method" => "connection.down", "params" => %{"id" => id}}) do
    case YellowDog.Netman.deactivate(id) do
      :ok -> %{"result" => "deactivated"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  def handle_command(%{"method" => "connection.add", "params" => %{"file" => path}}) do
    case YellowDog.Netman.import_profile(path) do
      {:ok, profile} -> %{"result" => "imported: #{profile.id}"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  def handle_command(%{"method" => "connection.delete", "params" => %{"id" => id}}) do
    case YellowDog.Netman.delete_profile(id) do
      :ok -> %{"result" => "deleted"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  def handle_command(%{"method" => method}) do
    %{"error" => "unknown method: #{method}"}
  end

  def handle_command(_) do
    %{"error" => "invalid command format"}
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
