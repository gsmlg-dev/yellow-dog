defmodule YellowDog.Dns.Handler.TCP do
  @moduledoc """
  TCP DNS message handler implementing the ThousandIsland.Handler behaviour.

  This handler focuses ONLY on network I/O:
  - On connection: start connection process for tracking queries
  - Handle DNS over TCP message framing (2-byte length prefix per RFC 1035)
  - Forward raw message bytes to connection process (no DNS parsing)
  - Send raw responses from connection process to client
  - On connection close: notify connection process to terminate

  All DNS protocol handling (parsing, resolution, encoding) is done by
  ConnectionProcess, ViewManager, View, and Zone processes.

  ## DNS over TCP (RFC 1035, RFC 7766)

  DNS messages over TCP are prefixed with a 2-byte length field:
  - Length: 2 bytes, big-endian unsigned integer
  - Message: DNS message bytes (length specified by length field)

  TCP connections support:
  - Multiple queries per connection (pipelining)
  - Out-of-order responses (matched by query ID)
  - Connection reuse for efficiency
  """

  use ThousandIsland.Handler

  alias YellowDog.Dns.{ConnectionManager, IpFormat}
  alias YellowDog.Telemetry

  ## ThousandIsland.Handler Callbacks

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {client_ip, client_port}} ->
        Telemetry.debug("DNS TCP connection established", %{
          client_ip: IpFormat.format(client_ip),
          client_port: client_port
        })

        # Start connection process for tracking queries
        case ConnectionManager.start_connection(self(), client_ip, client_port, socket: socket) do
          {:ok, conn_pid} ->
            state = %{
              client_ip: client_ip,
              client_port: client_port,
              connection_pid: conn_pid,
              buffer: <<>>
            }

            {:continue, state}

          {:error, reason} ->
            Telemetry.error("Failed to start connection process", %{
              client_ip: IpFormat.format(client_ip),
              reason: inspect(reason)
            })

            {:close, %{}}
        end

      {:error, reason} ->
        Telemetry.error("Failed to get peer name", %{reason: inspect(reason)})
        {:close, %{}}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    # Append new data to buffer
    buffer = state.buffer <> data

    # Process complete messages from buffer
    process_buffer(buffer, socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    Telemetry.debug("DNS TCP connection timeout", %{
      client_ip: IpFormat.format(state.client_ip)
    })

    # Notify connection process
    if Map.get(state, :connection_pid) do
      YellowDog.Dns.ConnectionProcess.connection_closed(state.connection_pid)
    end

    {:close, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Telemetry.debug("DNS TCP connection closed", %{
      client_ip: IpFormat.format(Map.get(state, :client_ip, :unknown))
    })

    # Notify connection process
    if Map.get(state, :connection_pid) do
      YellowDog.Dns.ConnectionProcess.connection_closed(state.connection_pid)
    end

    :ok
  end

  # Handle async raw responses from ConnectionProcess
  @impl GenServer
  def handle_info({:dns_raw_response, query_id, response_data}, {socket, state}) do
    Telemetry.debug("Sending DNS TCP response", %{
      query_id: query_id,
      client_ip: IpFormat.format(state.client_ip)
    })

    send_raw_response(response_data, socket)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info(_msg, {socket, state}) do
    {:noreply, {socket, state}, socket.read_timeout}
  end

  ## Private Functions

  # Process buffer for complete DNS messages (framing only, no parsing)
  defp process_buffer(buffer, socket, state) do
    case extract_framed_message(buffer) do
      {:ok, message_data, remaining} ->
        # Handle the raw message
        handle_raw_message(message_data, state)
        # Continue processing remaining buffer
        process_buffer(remaining, socket, %{state | buffer: <<>>})

      {:incomplete, _} ->
        # Need more data - save buffer and wait
        {:continue, %{state | buffer: buffer}}
    end
  end

  # Extract framed message (2-byte length prefix per RFC 1035)
  # Does NOT parse DNS content - just extracts the raw bytes
  defp extract_framed_message(<<>>) do
    {:incomplete, :need_length}
  end

  defp extract_framed_message(<<_partial::binary-size(1)>>) do
    {:incomplete, :need_length}
  end

  defp extract_framed_message(<<length::16, rest::binary>>) when byte_size(rest) < length do
    {:incomplete, {:need_message, length, byte_size(rest)}}
  end

  defp extract_framed_message(<<length::16, message::binary-size(length), remaining::binary>>) do
    {:ok, message, remaining}
  end

  defp extract_framed_message(_) do
    {:incomplete, :invalid_framing}
  end

  defp handle_raw_message(message_data, state) do
    Telemetry.debug("Received DNS TCP message", %{
      client_ip: IpFormat.format(state.client_ip),
      size: byte_size(message_data)
    })

    # Submit raw data to connection process (non-blocking for pipelining support)
    case YellowDog.Dns.ConnectionProcess.submit_raw_data(state.connection_pid, message_data) do
      :ok ->
        # Response will arrive via handle_info
        :ok

      {:error, reason} ->
        Telemetry.warning("Failed to submit TCP message", %{reason: inspect(reason)})
        # ConnectionProcess will handle errors and send appropriate response
    end
  end

  defp send_raw_response(response_data, socket) do
    length = IO.iodata_length(response_data)

    # RFC 1035: 2-byte length prefix (big-endian) followed by message
    framed_message = [<<length::16>>, response_data]

    case ThousandIsland.Socket.send(socket, framed_message) do
      :ok ->
        Telemetry.debug("Sent DNS TCP response", %{
          size: length
        })

      {:error, reason} ->
        Telemetry.error("Failed to send DNS TCP response", %{
          reason: inspect(reason)
        })
    end
  end

end
