defmodule YellowDog.Dns.Handler.TCP do
  @moduledoc """
  TCP DNS message handler implementing the ThousandIsland.Handler behaviour.

  This handler focuses ONLY on network I/O:
  - On connection: start connection process for tracking queries
  - Handle DNS over TCP message framing (2-byte length prefix per RFC 1035)
  - Forward all queries to connection process
  - Send responses from connection process to client
  - On connection close: notify connection process to terminate

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

  alias YellowDog.Telemetry
  alias YellowDog.Dns.ConnectionManager
  alias DNS.Message

  ## ThousandIsland.Handler Callbacks

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {client_ip, client_port}} ->
        Telemetry.debug("DNS TCP connection established", %{
          client_ip: format_ip(client_ip),
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
              client_ip: format_ip(client_ip),
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
      client_ip: format_ip(state.client_ip)
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
      client_ip: format_ip(Map.get(state, :client_ip, :unknown))
    })

    # Notify connection process
    if Map.get(state, :connection_pid) do
      YellowDog.Dns.ConnectionProcess.connection_closed(state.connection_pid)
    end

    :ok
  end

  # Handle async messages from ConnectionProcess
  @impl GenServer
  def handle_info({:dns_response, query_id, response}, {socket, state}) do
    Telemetry.debug("Sending DNS TCP response", %{
      query_id: query_id,
      client_ip: format_ip(state.client_ip)
    })

    send_response(response, socket)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info({:resolution_complete, query_id, response}, {socket, state}) do
    Telemetry.debug("Sending DNS TCP response (resolution complete)", %{
      query_id: query_id,
      client_ip: format_ip(state.client_ip)
    })

    send_response(response, socket)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info({:resolution_error, query_id, reason}, {socket, state}) do
    Telemetry.warning("DNS resolution error", %{
      query_id: query_id,
      reason: inspect(reason)
    })

    # We can't easily create error response without the original query
    # The ConnectionProcess should have sent proper error response
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info(_msg, {socket, state}) do
    {:noreply, {socket, state}, socket.read_timeout}
  end

  ## Private Functions

  # Process buffer for complete DNS messages
  defp process_buffer(buffer, socket, state) do
    case parse_dns_message(buffer) do
      {:ok, query, remaining} ->
        # Handle the query
        handle_query(query, socket, state)
        # Continue processing remaining buffer
        process_buffer(remaining, socket, %{state | buffer: <<>>})

      {:incomplete, _} ->
        # Need more data - save buffer and wait
        {:continue, %{state | buffer: buffer}}

      {:error, reason} ->
        Telemetry.warning("Failed to parse DNS TCP message", %{
          client_ip: format_ip(state.client_ip),
          reason: inspect(reason)
        })

        {:close, state}
    end
  end

  # Parse DNS message with 2-byte length framing (RFC 1035)
  defp parse_dns_message(<<>>) do
    {:incomplete, :need_length}
  end

  defp parse_dns_message(<<_partial::binary-size(1)>>) do
    {:incomplete, :need_length}
  end

  defp parse_dns_message(<<length::16, rest::binary>>) when byte_size(rest) < length do
    {:incomplete, {:need_message, length, byte_size(rest)}}
  end

  defp parse_dns_message(<<length::16, message::binary-size(length), remaining::binary>>) do
    try do
      query = Message.from_iodata(message)
      {:ok, query, remaining}
    rescue
      error -> {:error, {:parse_error, error}}
    catch
      {:format_error, section, _details} ->
        {:error, {:format_error, section}}

      :throw, reason ->
        {:error, reason}
    end
  end

  defp parse_dns_message(_) do
    {:error, :invalid_framing}
  end

  defp handle_query(query, socket, state) do
    Telemetry.debug("Received DNS TCP query", %{
      client_ip: format_ip(state.client_ip),
      query: inspect_query(query)
    })

    # Submit query to connection process (non-blocking for pipelining support)
    case YellowDog.Dns.ConnectionProcess.submit_query(state.connection_pid, query) do
      :ok ->
        # Response will arrive via handle_info
        :ok

      {:error, reason} ->
        Telemetry.warning("Failed to submit TCP query", %{reason: inspect(reason)})
        # Send error response
        response = create_error_response(query, :servfail)
        send_response(response, socket)
    end
  end

  defp create_error_response(query, reason) do
    rcode =
      case reason do
        :format_error -> :formerr
        :servfail -> :servfail
        :refused -> :refused
        :nxdomain -> :nxdomain
        :timeout -> :servfail
        _ -> :servfail
      end

    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 0,
          tc: 0,
          ra: 1,
          rcode: rcode
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp send_response(response, socket) do
    data = DNS.to_iodata(response)
    length = IO.iodata_length(data)

    # RFC 1035: 2-byte length prefix (big-endian) followed by message
    framed_message = [<<length::16>>, data]

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

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp format_ip(other), do: inspect(other)

  defp inspect_query(query) do
    case query.qdlist do
      [question | _] ->
        "#{question.name} #{question.type} #{question.class}"

      _ ->
        "empty query"
    end
  end
end
