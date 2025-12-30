defmodule YellowDog.Dns.Handler.UDP do
  @moduledoc """
  UDP DNS message handler implementing the Abyss.Handler behaviour.

  This handler focuses ONLY on network I/O:
  - On first request: call ConnectionManager to start connection process
  - Forward all raw data to connection process (no parsing)
  - Send raw responses from connection process to client
  - On network connection close: notify connection process to terminate

  All DNS protocol handling (parsing, resolution, encoding) is done by
  ConnectionProcess, ViewManager, View, and Zone processes.

  ## Lifecycle

  1 network connection = 1 Handler process = 1 connection process
  UDP: typically one query, then connection closes
  TCP: potentially multiple concurrent queries, terminates when TCP closes
  """

  use Abyss.Handler

  alias YellowDog.Telemetry
  alias YellowDog.Dns.ConnectionManager

  ## Abyss.Handler Callbacks

  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    Telemetry.debug("DNS UDP received data", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      size: byte_size(data)
    })

    handle_raw_data(data, client_ip, client_port, state)
  end

  @impl true
  def handle_error(error, state) do
    Telemetry.error("DNS handler error", %{error: inspect(error)})
    {:continue, state}
  end

  @impl true
  def handle_timeout(state) do
    Telemetry.debug("DNS handler timeout")

    # Notify connection process if it exists
    if Map.get(state, :connection_pid) do
      YellowDog.Dns.ConnectionProcess.connection_closed(state.connection_pid)
    end

    {:continue, state}
  end

  ## Private Functions

  defp handle_raw_data(data, client_ip, client_port, state) do
    Telemetry.debug("Received DNS data", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      size: byte_size(data)
    })

    # Get or start connection process
    case get_or_start_connection(state, client_ip, client_port) do
      {:ok, conn_pid, new_state} ->
        # Submit raw data to connection process
        case YellowDog.Dns.ConnectionProcess.submit_raw_data(conn_pid, data) do
          :ok ->
            # Wait for raw response from connection process
            receive do
              {:dns_raw_response, _query_id, response_data} ->
                send_raw_response(response_data, client_ip, client_port, new_state.socket)
                {:close, new_state}
            after
              10_000 ->
                # Timeout waiting for response
                Telemetry.warning("Timeout waiting for DNS response", %{
                  client_ip: format_ip(client_ip),
                  data_size: byte_size(data)
                })
                {:close, new_state}
            end

          {:error, reason} ->
            Telemetry.warning("Failed to submit data to connection process", %{
              reason: inspect(reason)
            })
            {:close, state}
        end

      {:error, reason} ->
        Telemetry.error("Failed to start connection process", %{reason: inspect(reason)})
        {:close, state}
    end
  end

  defp get_or_start_connection(state, client_ip, client_port) do
    case Map.get(state, :connection_pid) do
      nil ->
        # Start new connection process
        case ConnectionManager.start_connection(self(), client_ip, client_port,
               socket: state.socket
             ) do
          {:ok, pid} ->
            {:ok, pid, Map.put(state, :connection_pid, pid)}

          {:error, reason} ->
            {:error, reason}
        end

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid, state}
        else
          # Connection died, start new one
          case ConnectionManager.start_connection(self(), client_ip, client_port,
                 socket: state.socket
               ) do
            {:ok, new_pid} ->
              {:ok, new_pid, Map.put(state, :connection_pid, new_pid)}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp send_raw_response(response_data, client_ip, client_port, socket) do
    case Abyss.Transport.UDP.send(socket, client_ip, client_port, response_data) do
      :ok ->
        Telemetry.debug("Sent DNS response", %{
          client_ip: format_ip(client_ip),
          client_port: client_port,
          size: IO.iodata_length(response_data)
        })

      {:error, reason} ->
        Telemetry.error("Failed to send DNS response", %{
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
end
