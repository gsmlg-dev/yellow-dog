defmodule DHCPv4.Client do
  @moduledoc """
  DHCP client utilities for testing and simulation.

  Provides functions to simulate DHCP client behavior for testing
  DHCP server implementations.
  """

  alias DHCPv4.Message
  alias DHCPv4.Message.Option
  alias DHCP.SecureRandom

  @doc """
  Create a DHCPDISCOVER message for testing.

  ## Options

    * `:mac` - Client MAC address (required)
    * `:hostname` - Hostname to include (optional)
    * `:requested_ip` - IP to request (optional)
    * `:xid` - Transaction ID (auto-generated if not provided)
  """
  @spec discover(keyword()) :: Message.t()
  def discover(opts) do
    mac = Keyword.fetch!(opts, :mac)
    xid = Keyword.get(opts, :xid, SecureRandom.generate_dhcpv4_xid())
    hostname = Keyword.get(opts, :hostname)
    requested_ip = Keyword.get(opts, :requested_ip)

    Message.new()
    # BOOTREQUEST
    |> Map.put(:op, 1)
    # Ethernet
    |> Map.put(:htype, 1)
    # MAC length
    |> Map.put(:hlen, 6)
    |> Map.put(:xid, xid)
    |> Map.put(:chaddr, pad_mac(mac))
    # DHCPDISCOVER
    |> add_option(53, 1, <<1>>)
    |> maybe_add_option(12, hostname)
    |> maybe_add_option(50, requested_ip)
  end

  @doc """
  Create a DHCPREQUEST message for testing.

  ## Options

    * `:mac` - Client MAC address (required)
    * `:server_ip` - Server IP to request from (required)
    * `:requested_ip` - IP to request (required)
    * `:xid` - Transaction ID (auto-generated if not provided)
  """
  @spec request(keyword()) :: Message.t()
  def request(opts) do
    mac = Keyword.fetch!(opts, :mac)
    server_ip = Keyword.fetch!(opts, :server_ip)
    requested_ip = Keyword.fetch!(opts, :requested_ip)
    xid = Keyword.get(opts, :xid, SecureRandom.generate_dhcpv4_xid())

    Message.new()
    # BOOTREQUEST
    |> Map.put(:op, 1)
    # Ethernet
    |> Map.put(:htype, 1)
    # MAC length
    |> Map.put(:hlen, 6)
    |> Map.put(:xid, xid)
    |> Map.put(:chaddr, pad_mac(mac))
    # DHCPREQUEST
    |> add_option(53, 1, <<3>>)
    |> add_option(54, 4, ip_to_binary(server_ip))
    |> add_option(50, 4, ip_to_binary(requested_ip))
  end

  @doc """
  Create a DHCPRELEASE message for testing.

  ## Options

    * `:mac` - Client MAC address (required)
    * `:server_ip` - Server IP to release to (required)
    * `:leased_ip` - IP to release (required)
    * `:xid` - Transaction ID (auto-generated if not provided)
  """
  @spec release(keyword()) :: Message.t()
  def release(opts) do
    mac = Keyword.fetch!(opts, :mac)
    server_ip = Keyword.fetch!(opts, :server_ip)
    leased_ip = Keyword.fetch!(opts, :leased_ip)
    xid = Keyword.get(opts, :xid, SecureRandom.generate_dhcpv4_xid())

    Message.new()
    # BOOTREQUEST
    |> Map.put(:op, 1)
    # Ethernet
    |> Map.put(:htype, 1)
    # MAC length
    |> Map.put(:hlen, 6)
    |> Map.put(:xid, xid)
    |> Map.put(:ciaddr, leased_ip)
    |> Map.put(:chaddr, pad_mac(mac))
    # DHCPRELEASE
    |> add_option(53, 1, <<7>>)
    |> add_option(54, 4, ip_to_binary(server_ip))
  end

  @doc """
  Create a DHCPDECLINE message for testing.

  ## Options

    * `:mac` - Client MAC address (required)
    * `:server_ip` - Server IP to decline from (required)
    * `:declined_ip` - IP to decline (required)
    * `:xid` - Transaction ID (auto-generated if not provided)
  """
  @spec decline(keyword()) :: Message.t()
  def decline(opts) do
    mac = Keyword.fetch!(opts, :mac)
    server_ip = Keyword.fetch!(opts, :server_ip)
    declined_ip = Keyword.fetch!(opts, :declined_ip)
    xid = Keyword.get(opts, :xid, SecureRandom.generate_dhcpv4_xid())

    Message.new()
    # BOOTREQUEST
    |> Map.put(:op, 1)
    # Ethernet
    |> Map.put(:htype, 1)
    # MAC length
    |> Map.put(:hlen, 6)
    |> Map.put(:xid, xid)
    |> Map.put(:chaddr, pad_mac(mac))
    # DHCPDECLINE
    |> add_option(53, 1, <<4>>)
    |> add_option(54, 4, ip_to_binary(server_ip))
    |> add_option(50, 4, ip_to_binary(declined_ip))
  end

  @doc """
  Send a DHCP message to a server for testing.

  ## Options

    * `:message` - Message to send (required)
    * `:server_ip` - Server IP to send to (default: {255, 255, 255, 255})
    * `:timeout` - Timeout in milliseconds (default: 5000)
  """
  @spec send_message(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def send_message(opts) do
    message = Keyword.fetch!(opts, :message)
    server_ip = Keyword.get(opts, :server_ip, {255, 255, 255, 255})
    timeout = Keyword.get(opts, :timeout, 5000)

    binary_message = DHCP.to_iodata(message)

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, server_ip, 67, binary_message)

          case :gen_udp.recv(socket, 2048, timeout) do
            {:ok, {_ip, _port, response}} ->
              {:ok, Message.from_iodata(response)}

            {:error, reason} ->
              {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run a complete DHCP lease test cycle.

  Returns the full DHCP handshake process for testing.
  """
  @spec test_lease_cycle(keyword()) ::
          {:ok,
           %{discover: Message.t(), offer: Message.t(), request: Message.t(), ack: Message.t()}}
          | {:error, term()}
  def test_lease_cycle(opts) do
    mac = Keyword.fetch!(opts, :mac)
    server_ip = Keyword.get(opts, :server_ip, {255, 255, 255, 255})

    with {:ok, offer} <- send_discover(mac, server_ip),
         {:ok, ack} <- send_request(mac, server_ip, offer.yiaddr) do
      {:ok,
       %{
         discover: discover(mac),
         offer: offer,
         request: request(mac: mac, server_ip: server_ip, requested_ip: offer.yiaddr),
         ack: ack
       }}
    end
  end

  ## Private functions

  defp send_discover(mac, server_ip) do
    message = discover(mac: mac)
    send_message(message: message, server_ip: server_ip)
  end

  defp send_request(mac, server_ip, requested_ip) do
    message = request(mac: mac, server_ip: server_ip, requested_ip: requested_ip)
    send_message(message: message, server_ip: server_ip)
  end

  defp pad_mac(mac) when is_binary(mac) and byte_size(mac) == 6 do
    # Pad to 16 bytes
    <<mac::binary, 0::size(10 * 8)>>
  end

  defp pad_mac(mac) when is_binary(mac) and byte_size(mac) < 6 do
    <<mac::binary, 0::size((16 - byte_size(mac)) * 8)>>
  end

  defp maybe_add_option(message, _type, nil), do: message

  defp maybe_add_option(message, type, value) when is_binary(value) do
    option = Option.new(type, byte_size(value), value)
    %{message | options: [option | message.options]}
  end

  defp maybe_add_option(message, type, ip) when is_tuple(ip) do
    option = Option.new(type, 4, ip_to_binary(ip))
    %{message | options: [option | message.options]}
  end

  defp add_option(message, type, length, value) do
    option = Option.new(type, length, value)
    %{message | options: [option | message.options]}
  end

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>
end
