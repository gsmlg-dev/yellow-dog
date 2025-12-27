defmodule YellowDog.Dns.Handler.UDP do
  @moduledoc """
  UDP DNS message handler implementing the Abyss.Handler behaviour.

  This handler focuses ONLY on network I/O:
  - On first request: call ConnectionManager to start connection process
  - Forward all queries to connection process
  - Send responses from connection process to client
  - On network connection close: notify connection process to terminate

  All DNS resolution logic is handled by ConnectionProcess, ViewManager,
  View, and Zone processes.

  ## Lifecycle

  1 network connection = 1 Handler process = 1 connection process
  UDP: typically one query, then connection closes
  TCP: potentially multiple concurrent queries, terminates when TCP closes
  """

  use Abyss.Handler

  alias YellowDog.Telemetry
  alias YellowDog.Dns.ConnectionManager
  alias DNS.Message

  ## Abyss.Handler Callbacks

  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    Telemetry.debug("DNS UDP received data", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      size: byte_size(data)
    })

    try do
      # Parse incoming DNS message
      query = Message.from_iodata(data)
      handle_query(query, client_ip, client_port, state)
    rescue
      error ->
        handle_exception(error, __STACKTRACE__, client_ip, client_port, state)
    catch
      {:format_error, section, _details} ->
        handle_parse_error({:format_error, section}, client_ip, client_port, state)

      :throw, reason ->
        handle_parse_error(reason, client_ip, client_port, state)
    end
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

  defp handle_query(query, client_ip, client_port, state) do
    Telemetry.debug("Received DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      query: inspect_query(query)
    })

    # Get or start connection process
    case get_or_start_connection(state, client_ip, client_port) do
      {:ok, conn_pid, new_state} ->
        # Submit query to connection process
        case YellowDog.Dns.ConnectionProcess.submit_query(conn_pid, query) do
          :ok ->
            # Wait for response from connection process
            receive do
              {:dns_response, _query_id, response} ->
                send_response(response, client_ip, client_port, new_state.socket)
                {:close, new_state}

              {:resolution_complete, _query_id, response} ->
                send_response(response, client_ip, client_port, new_state.socket)
                {:close, new_state}

              {:resolution_error, _query_id, reason} ->
                response = create_error_response(query, reason)
                send_response(response, client_ip, client_port, new_state.socket)
                {:close, new_state}
            after
              10_000 ->
                # Timeout waiting for response
                Telemetry.warning("Timeout waiting for DNS response", %{
                  client_ip: format_ip(client_ip),
                  query: inspect_query(query)
                })

                response = create_error_response(query, :servfail)
                send_response(response, client_ip, client_port, new_state.socket)
                {:close, new_state}
            end

          {:error, reason} ->
            Telemetry.warning("Failed to submit query", %{reason: inspect(reason)})
            response = create_error_response(query, :servfail)
            send_response(response, client_ip, client_port, state.socket)
            {:close, state}
        end

      {:error, reason} ->
        Telemetry.error("Failed to start connection process", %{reason: inspect(reason)})

        # Fallback to direct forwarding
        case fallback_resolve(query) do
          {:ok, response} ->
            send_response(response, client_ip, client_port, state.socket)

          {:error, _} ->
            response = create_error_response(query, :servfail)
            send_response(response, client_ip, client_port, state.socket)
        end

        {:close, state}
    end
  end

  defp get_or_start_connection(state, client_ip, client_port) do
    case Map.get(state, :connection_pid) do
      nil ->
        # Start new connection process
        case ConnectionManager.start_connection(self(), client_ip, client_port, socket: state.socket) do
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
          case ConnectionManager.start_connection(self(), client_ip, client_port, socket: state.socket) do
            {:ok, new_pid} ->
              {:ok, new_pid, Map.put(state, :connection_pid, new_pid)}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp handle_parse_error(reason, client_ip, client_port, state) do
    Telemetry.warning("Failed to parse DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      reason: inspect(reason)
    })

    # Can't send error response without parsing query ID
    {:close, state}
  end

  defp handle_exception(error, stacktrace, client_ip, client_port, state) do
    Telemetry.error("Exception handling DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      error: inspect(error),
      stacktrace: Exception.format_stacktrace(stacktrace)
    })

    {:close, state}
  end

  # Fallback resolution for when ConnectionManager is not available
  defp fallback_resolve(query) do
    upstreams = get_upstreams()

    if upstreams == [] do
      {:error, :refused}
    else
      forward_to_upstream(query, upstreams)
    end
  end

  defp get_upstreams do
    case apply(YellowDog.Config, :get, [:dns, :upstream_servers]) do
      nil ->
        [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]

      servers when is_list(servers) ->
        Enum.map(servers, fn
          {ip, port} when is_tuple(ip) -> {ip, port}
          ip when is_tuple(ip) -> {ip, 53}
          ip_str when is_binary(ip_str) -> parse_upstream_string(ip_str)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
  end

  defp parse_upstream_string(str) do
    case String.split(str, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {ip, port}
        else
          _ -> nil
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {ip, 53}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      _ -> :error
    end
  end

  defp forward_to_upstream(query, upstreams) do
    data = DNS.to_iodata(query)

    Enum.reduce_while(upstreams, {:error, :no_response}, fn {ip, port}, _acc ->
      case query_upstream(ip, port, data) do
        {:ok, response} -> {:halt, {:ok, response}}
        {:error, _} -> {:cont, {:error, :no_response}}
      end
    end)
  end

  defp query_upstream(ip, port, data) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_udp.send(socket, ip, port, data)

        result =
          case :gen_udp.recv(socket, 0, 5000) do
            {:ok, {_ip, _port, response_data}} ->
              try do
                {:ok, Message.from_iodata(response_data)}
              catch
                :throw, reason -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
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

  defp send_response(response, client_ip, client_port, socket) do
    data = DNS.to_iodata(response)

    case Abyss.Transport.UDP.send(socket, client_ip, client_port, data) do
      :ok ->
        Telemetry.debug("Sent DNS response", %{
          client_ip: format_ip(client_ip),
          client_port: client_port
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

  defp inspect_query(query) do
    case query.qdlist do
      [question | _] ->
        "#{question.name} #{question.type} #{question.class}"

      _ ->
        "empty query"
    end
  end
end
