defmodule YellowDog.Dns.Handler.UDP do
  @moduledoc """
  UDP DNS message handler implementing the Abyss.Handler behaviour.

  Processes DNS queries over UDP with proper error handling and logging.
  Supports all standard DNS query types and integrates with the
  YellowDog DNS resolution system.
  """

  use Abyss.Handler
  require Logger

  @impl true
  def handle_data({client_ip, client_port, data}, %{socket: listener_socket} = state) do
    try do
      # Parse incoming DNS message
      message = DNS.Message.from_iodata(data)
      handle_dns_message(message, client_ip, client_port, listener_socket, state)
    rescue
      error ->
        Logger.error("Error handling DNS message from #{format_ip(client_ip)}:#{client_port}: #{inspect(error)}")
        {:continue, state}
    end
  end

  @impl true
  def handle_error(error, state) do
    Logger.error("DNS handler error: #{inspect(error)}")
    {:continue, state}
  end

  @impl true
  def handle_timeout(state) do
    Logger.debug("DNS handler timeout")
    {:continue, state}
  end

  # Private functions

  defp handle_dns_message(message, client_ip, client_port, listener_socket, state) do
    # Store client info in the message for later use
    message = Map.put(message, :client_ip, client_ip) |> Map.put(:client_port, client_port)

    # Resolve the DNS query
    case YellowDog.Dns.NameResolver.resolve(message) do
      {:ok, response} ->
        # Send response back to client
        response_data = DNS.to_iodata(response)
        Abyss.Transport.UDP.send(listener_socket, client_ip, client_port, response_data)
        Logger.debug("DNS response sent to #{format_ip(client_ip)}:#{client_port}")

      {:error, reason} ->
        Logger.warning("Failed to resolve DNS query from #{format_ip(client_ip)}:#{client_port}: #{inspect(reason)}")
        # Could send a DNS error response here if needed

      response ->
        # Handle case where NameResolver returns a response directly
        response_data = DNS.to_iodata(response)
        Abyss.Transport.UDP.send(listener_socket, client_ip, client_port, response_data)
        Logger.debug("DNS response sent to #{format_ip(client_ip)}:#{client_port}")
    end

    {:close, state}
  end

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    # Format IPv6 address as compressed string
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))

    # Basic compression - replace longest sequence of 0s with ::
    hex_str = Enum.join(hex_parts, ":")

    # Simple compression for common cases
    hex_str
    |> String.replace(":0:0:0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0", "::")
    |> String.replace(":0:0:0", "::")
    |> String.replace(":0:0", "::")
  end
end
