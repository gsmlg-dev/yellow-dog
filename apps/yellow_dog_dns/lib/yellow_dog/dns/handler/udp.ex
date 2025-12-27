defmodule YellowDog.Dns.Handler.UDP do
  @moduledoc """
  UDP DNS message handler implementing the Abyss.Handler behaviour.

  This handler focuses ONLY on network I/O:
  - Parse incoming DNS query
  - Create TSI (Telemetry Span Item) with request metadata
  - Delegate resolution to Server (which routes to ViewManager)
  - Send response back to client
  - Emit telemetry events

  All DNS resolution logic is handled by the ViewManager, View, and Zone processes.
  """

  use Abyss.Handler

  alias YellowDog.Telemetry
  alias YellowDog.Dns.TSI
  alias YellowDog.Dns.SpanManager
  alias YellowDog.Dns.Server
  alias DNS.Message

  ## Abyss.Handler Callbacks

  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    # Create TSI before parsing to track even failed parses
    tsi = TSI.new_raw(client_ip, client_port)
    IO.inspect({:dns, :udp, tsi})
    Telemetry.info("handle dns udp #{inspect(tsi)}")

    try do
      # Parse incoming DNS message (returns struct directly, throws on error)
      query = Message.from_iodata(data)
      handle_query(query, tsi, client_ip, client_port, state)
    rescue
      error ->
        handle_exception(error, __STACKTRACE__, tsi, client_ip, client_port, state)
    catch
      {:format_error, section, _details} ->
        handle_parse_error({:format_error, section}, tsi, client_ip, client_port, state)

      :throw, reason ->
        handle_parse_error(reason, tsi, client_ip, client_port, state)
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
    {:continue, state}
  end

  ## Private Functions

  defp handle_query(query, tsi, client_ip, client_port, state) do
    # Update TSI with parsed query
    tsi = TSI.set_query(tsi, query)

    Telemetry.debug("Received DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      query: inspect_query(query)
    })

    # Register TSI with SpanManager
    tsi = register_tsi(tsi)

    # Delegate resolution to Server (which routes to ViewManager)
    case resolve_query(tsi) do
      {:ok, response} ->
        # Complete the TSI
        tsi = TSI.complete(tsi, response)
        complete_tsi(tsi)

        # Send response back to client
        send_response(response, client_ip, client_port, state.socket)

        {:close, state}

      {:error, reason} ->
        # Create error response
        tsi = TSI.complete_error(tsi)
        complete_tsi(tsi)

        response = create_error_response(query, reason)
        send_response(response, client_ip, client_port, state.socket)

        {:close, state}
    end
  end

  defp handle_parse_error(reason, tsi, client_ip, client_port, state) do
    Telemetry.warning("Failed to parse DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      reason: inspect(reason)
    })

    # Complete TSI with error
    tsi = TSI.complete_error(tsi)
    complete_tsi(tsi)

    # Can't send error response without parsing query ID
    {:close, state}
  end

  defp handle_exception(error, stacktrace, tsi, client_ip, client_port, state) do
    Telemetry.error("Exception handling DNS query", %{
      client_ip: format_ip(client_ip),
      client_port: client_port,
      error: inspect(error),
      stacktrace: Exception.format_stacktrace(stacktrace)
    })

    # Complete TSI with error
    tsi = TSI.complete_error(tsi)
    complete_tsi(tsi)

    {:close, state}
  end

  defp resolve_query(tsi) do
    # Delegate to Server which routes to ViewManager
    try do
      Server.resolve(tsi)
    catch
      :exit, {:noproc, _} ->
        # Server not running, try forwarding directly
        fallback_resolve(tsi)

      :exit, reason ->
        Telemetry.warning("Resolution failed", %{reason: inspect(reason)})
        {:error, :servfail}
    end
  end

  defp fallback_resolve(tsi) do
    # Fallback for when Server/ViewManager isn't running
    # Try to forward to upstream servers directly
    query = tsi.query

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

  defp register_tsi(tsi) do
    try do
      SpanManager.register(tsi)
    catch
      :exit, _ -> tsi
    end
  end

  defp complete_tsi(tsi) do
    try do
      SpanManager.complete(tsi)
    catch
      :exit, _ -> tsi
    end
  end

  defp create_error_response(query, reason) do
    rcode =
      case reason do
        :format_error -> :formerr
        :servfail -> :servfail
        :refused -> :refused
        :nxdomain -> :nxdomain
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
    case query.questions do
      [question | _] ->
        "#{question.name} #{question.type} #{question.class}"

      _ ->
        "empty query"
    end
  end
end
