defmodule YellowDog.Netboot.TFTP.Server do
  @moduledoc """
  TFTP server UDP listener.

  Listens for RRQ packets on the configured port, validates requests,
  and spawns transfer workers for each valid request.
  """

  use GenServer

  alias YellowDog.Netboot.TFTP.{Protocol, FileIndex, TransferSupervisor}

  require Logger

  @default_port 69
  @default_root "/srv/netboot/tftp"

  defstruct [:socket, :port, :root_dir, :running]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current server status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Get the configured root directory."
  @spec root_dir() :: String.t()
  def root_dir do
    GenServer.call(__MODULE__, :root_dir)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    port = get_in_config(config, [:tftp_port], @default_port)
    root = get_in_config(config, [:tftp_root], @default_root)

    FileIndex.init()

    case ensure_root(root) do
      :ok ->
        FileIndex.scan(root)
        start_server(port, root)

      {:error, reason} ->
        Logger.warning("TFTP root #{root} is unavailable, server not started: #{inspect(reason)}")
        {:ok, %__MODULE__{port: port, root_dir: root, running: false}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running: state.running,
      port: state.port,
      root_dir: state.root_dir,
      file_count: if(state.running, do: FileIndex.count(), else: 0),
      active_transfers: TransferSupervisor.active_count()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:root_dir, _from, state) do
    {:reply, state.root_dir, state}
  end

  @impl true
  def handle_info({:udp, _socket, client_addr, client_port, packet}, state) do
    case Protocol.decode(packet) do
      {:ok, {:rrq, filename, _mode, opts}} ->
        handle_rrq(filename, client_addr, client_port, opts, state)

      {:ok, {:wrq, _filename, _mode, _opts}} ->
        send_error(state.socket, client_addr, client_port, 2)
        emit_request_telemetry(:rejected, %{reason: :write_not_allowed})

      _ ->
        send_error(state.socket, client_addr, client_port, 4)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp ensure_root(root) when is_binary(root) do
    with :ok <- File.mkdir_p(root),
         true <- File.dir?(root) do
      :ok
    else
      false -> {:error, :not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_root(root), do: {:error, {:invalid_root, root}}

  defp start_server(port, root) do
    case Abyss.Transport.UDP.open(port, active: true) do
      {:ok, socket} ->
        {:ok, actual_port} = :inet.port(socket)

        Logger.info("TFTP server listening on port #{actual_port}, root: #{root}")

        {:ok,
         %__MODULE__{
           socket: socket,
           port: actual_port,
           root_dir: root,
           running: true
         }}

      {:error, reason} ->
        Logger.error("Failed to start TFTP server on port #{port}: #{inspect(reason)}")
        {:ok, %__MODULE__{port: port, root_dir: root, running: false}}
    end
  end

  defp handle_rrq(filename, client_addr, client_port, opts, state) do
    emit_request_telemetry(:received, %{filename: filename, client: client_addr})

    case FileIndex.lookup(filename, state.root_dir) do
      {:ok, abs_path, file_size} ->
        block_size = negotiate_block_size(opts)
        negotiated_opts = build_negotiated_opts(opts, block_size, file_size)

        TransferSupervisor.start_transfer(
          client_addr: client_addr,
          client_port: client_port,
          file_path: abs_path,
          block_size: block_size,
          options: negotiated_opts
        )

      {:error, :path_traversal} ->
        send_error(state.socket, client_addr, client_port, 2)
        emit_request_telemetry(:rejected, %{filename: filename, reason: :path_traversal})

      {:error, :not_found} ->
        send_error(state.socket, client_addr, client_port, 1)
        emit_request_telemetry(:rejected, %{filename: filename, reason: :not_found})
    end
  end

  defp negotiate_block_size(opts) do
    case Map.get(opts, "blksize") do
      nil ->
        Protocol.default_block_size()

      size_str ->
        size = String.to_integer(size_str)
        min(max(size, 8), 65464)
    end
  rescue
    ArgumentError -> Protocol.default_block_size()
  end

  defp build_negotiated_opts(opts, block_size, file_size) do
    negotiated = %{}

    negotiated =
      if Map.has_key?(opts, "blksize") do
        Map.put(negotiated, "blksize", to_string(block_size))
      else
        negotiated
      end

    if Map.has_key?(opts, "tsize") do
      Map.put(negotiated, "tsize", to_string(file_size))
    else
      negotiated
    end
  end

  defp send_error(socket, addr, port, code) do
    packet = Protocol.error_packet(code)
    Abyss.Transport.UDP.send(socket, addr, port, packet)
  end

  defp emit_request_telemetry(status, metadata) do
    :telemetry.execute(
      [:yellow_dog, :netboot, :tftp, :request, status],
      %{},
      metadata
    )
  rescue
    _ -> :ok
  end

  defp get_in_config(config, keys, default) when is_map(config) do
    Enum.reduce_while(keys, config, fn key, acc ->
      case acc do
        %{^key => val} -> {:cont, val}
        _ -> {:halt, default}
      end
    end)
  end

  defp get_in_config(_, _, default), do: default
end
