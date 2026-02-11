defmodule YellowDog.Netboot.TFTP.Transfer do
  @moduledoc """
  Per-transfer worker process for TFTP file serving.

  Each transfer opens an ephemeral UDP socket, sends DATA blocks,
  and waits for ACKs. Implements timeout and retry logic.
  """

  use GenServer, restart: :temporary

  alias YellowDog.Netboot.TFTP.Protocol

  @timeout_ms 30_000
  @max_retries 5

  defstruct [
    :socket,
    :client_addr,
    :client_port,
    :file_path,
    :file_data,
    :block_size,
    :total_size,
    :current_block,
    :bytes_sent,
    :retries,
    :started_at
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    client_addr = Keyword.fetch!(args, :client_addr)
    client_port = Keyword.fetch!(args, :client_port)
    file_path = Keyword.fetch!(args, :file_path)
    block_size = Keyword.get(args, :block_size, Protocol.default_block_size())
    opts = Keyword.get(args, :options, %{})

    case File.read(file_path) do
      {:ok, data} ->
        {:ok, socket} = :gen_udp.open(0, [:binary, active: true])

        state = %__MODULE__{
          socket: socket,
          client_addr: client_addr,
          client_port: client_port,
          file_path: file_path,
          file_data: data,
          block_size: block_size,
          total_size: byte_size(data),
          current_block: 0,
          bytes_sent: 0,
          retries: 0,
          started_at: System.monotonic_time(:millisecond)
        }

        emit_telemetry(:start, state)

        if map_size(opts) > 0 do
          send_oack(state, opts)
        else
          send_next_block(%{state | current_block: 1})
        end

        {:ok, state, @timeout_ms}

      {:error, reason} ->
        {:stop, {:file_error, reason}}
    end
  end

  @impl true
  def handle_info({:udp, _socket, _addr, _port, packet}, state) do
    case Protocol.decode(packet) do
      {:ok, {:ack, block}} when block == state.current_block ->
        if transfer_complete?(state) do
          emit_telemetry(:stop, state)
          {:stop, :normal, state}
        else
          state = %{state | current_block: block + 1, retries: 0}
          send_next_block(state)
          {:noreply, state, @timeout_ms}
        end

      {:ok, {:ack, 0}} when state.current_block == 0 ->
        state = %{state | current_block: 1, retries: 0}
        send_next_block(state)
        {:noreply, state, @timeout_ms}

      {:ok, {:error, code, msg}} ->
        emit_telemetry(:exception, state, %{error_code: code, error_message: msg})
        {:stop, {:client_error, code, msg}, state}

      _ ->
        {:noreply, state, @timeout_ms}
    end
  end

  def handle_info(:timeout, %{retries: retries} = state) when retries >= @max_retries do
    emit_telemetry(:exception, state, %{error_message: "timeout after #{@max_retries} retries"})
    {:stop, :timeout, state}
  end

  def handle_info(:timeout, state) do
    state = %{state | retries: state.retries + 1}
    resend_current_block(state)
    {:noreply, state, @timeout_ms}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket) do
    :gen_udp.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp send_next_block(state) do
    offset = (state.current_block - 1) * state.block_size
    remaining = byte_size(state.file_data) - offset
    chunk_size = min(remaining, state.block_size)

    if chunk_size >= 0 do
      chunk = binary_part(state.file_data, offset, max(chunk_size, 0))
      packet = Protocol.encode({:data, state.current_block, chunk})
      :gen_udp.send(state.socket, state.client_addr, state.client_port, packet)
    end
  end

  defp resend_current_block(state) do
    send_next_block(state)
  end

  defp send_oack(state, opts) do
    packet = Protocol.encode({:oack, opts})
    :gen_udp.send(state.socket, state.client_addr, state.client_port, packet)
  end

  defp transfer_complete?(state) do
    offset = state.current_block * state.block_size
    offset >= byte_size(state.file_data)
  end

  defp emit_telemetry(event, state, extra \\ %{}) do
    metadata =
      Map.merge(
        %{
          client_addr: state.client_addr,
          client_port: state.client_port,
          file_path: state.file_path,
          total_size: state.total_size,
          bytes_sent: state.current_block * state.block_size
        },
        extra
      )

    measurements =
      case event do
        :stop ->
          elapsed = System.monotonic_time(:millisecond) - state.started_at
          %{duration: elapsed, bytes: state.total_size}

        _ ->
          %{}
      end

    :telemetry.execute(
      [:yellow_dog, :netboot, :tftp, :transfer, event],
      measurements,
      metadata
    )
  rescue
    _ -> :ok
  end
end
