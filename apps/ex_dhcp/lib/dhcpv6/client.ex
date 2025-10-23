defmodule DHCPv6.Client do
  @moduledoc """
  DHCPv6 client utilities for testing and simulation.

  Provides functions to simulate DHCPv6 client behavior for testing
  DHCPv6 server implementations.
  """

  alias DHCPv6.Message
  alias DHCPv6.Message.Option
  alias DHCP.SecureRandom

  @doc """
  Create a SOLICIT message for testing.

  ## Options

    * `:duid` - Client DUID (required)
    * `:iaid` - Identity Association ID (required)
    * `:transaction_id` - Transaction ID (auto-generated if not provided)
    * `:rapid_commit` - Include rapid commit option (default: false)
    * `:dns_servers` - Request DNS servers (default: true)
  """
  @spec solicit(keyword()) :: Message.t()
  def solicit(opts) do
    duid = Keyword.fetch!(opts, :duid)
    iaid = Keyword.fetch!(opts, :iaid)

    transaction_id =
      Keyword.get(opts, :transaction_id, SecureRandom.generate_dhcpv6_transaction_id())

    rapid_commit = Keyword.get(opts, :rapid_commit, false)
    dns_servers = Keyword.get(opts, :dns_servers, true)

    Message.new()
    # SOLICIT
    |> Map.put(:msg_type, 1)
    |> Map.put(:transaction_id, <<transaction_id::24>>)
    # CLIENTID
    |> add_option(1, duid)
    |> add_ia_na(iaid)
    |> maybe_add_rapid_commit(rapid_commit)
    |> maybe_add_oro(dns_servers)
  end

  @doc """
  Create a REQUEST message for testing.

  ## Options

    * `:duid` - Client DUID (required)
    * `:server_duid` - Server DUID (required)
    * `:iaid` - Identity Association ID (required)
    * `:addresses` - Requested IPv6 addresses (required)
    * `:transaction_id` - Transaction ID (auto-generated if not provided)
  """
  @spec request(keyword()) :: Message.t()
  def request(opts) do
    duid = Keyword.fetch!(opts, :duid)
    server_duid = Keyword.fetch!(opts, :server_duid)
    iaid = Keyword.fetch!(opts, :iaid)
    addresses = Keyword.fetch!(opts, :addresses)

    transaction_id =
      Keyword.get(opts, :transaction_id, SecureRandom.generate_dhcpv6_transaction_id())

    Message.new()
    # REQUEST
    |> Map.put(:msg_type, 3)
    |> Map.put(:transaction_id, <<transaction_id::24>>)
    # CLIENTID
    |> add_option(1, duid)
    # SERVERID
    |> add_option(2, server_duid)
    |> add_ia_na(iaid, addresses)
  end

  @doc """
  Create a RENEW message for testing.

  ## Options

    * `:duid` - Client DUID (required)
    * `:server_duid` - Server DUID (required)
    * `:iaid` - Identity Association ID (required)
    * `:addresses` - IPv6 addresses to renew (required)
    * `:transaction_id` - Transaction ID (auto-generated if not provided)
  """
  @spec renew(keyword()) :: Message.t()
  def renew(opts) do
    duid = Keyword.fetch!(opts, :duid)
    server_duid = Keyword.fetch!(opts, :server_duid)
    iaid = Keyword.fetch!(opts, :iaid)
    addresses = Keyword.fetch!(opts, :addresses)

    transaction_id =
      Keyword.get(opts, :transaction_id, SecureRandom.generate_dhcpv6_transaction_id())

    Message.new()
    # RENEW
    |> Map.put(:msg_type, 5)
    |> Map.put(:transaction_id, <<transaction_id::24>>)
    # CLIENTID
    |> add_option(1, duid)
    # SERVERID
    |> add_option(2, server_duid)
    |> add_ia_na(iaid, addresses)
  end

  @doc """
  Create a RELEASE message for testing.

  ## Options

    * `:duid` - Client DUID (required)
    * `:server_duid` - Server DUID (required)
    * `:iaid` - Identity Association ID (required)
    * `:addresses` - IPv6 addresses to release (required)
    * `:transaction_id` - Transaction ID (auto-generated if not provided)
  """
  @spec release(keyword()) :: Message.t()
  def release(opts) do
    duid = Keyword.fetch!(opts, :duid)
    server_duid = Keyword.fetch!(opts, :server_duid)
    iaid = Keyword.fetch!(opts, :iaid)
    addresses = Keyword.fetch!(opts, :addresses)

    transaction_id =
      Keyword.get(opts, :transaction_id, SecureRandom.generate_dhcpv6_transaction_id())

    Message.new()
    # RELEASE
    |> Map.put(:msg_type, 8)
    |> Map.put(:transaction_id, <<transaction_id::24>>)
    # CLIENTID
    |> add_option(1, duid)
    # SERVERID
    |> add_option(2, server_duid)
    |> add_ia_na(iaid, addresses)
  end

  @doc """
  Create an INFORMATION-REQUEST message for testing.

  ## Options

    * `:duid` - Client DUID (required)
    * `:transaction_id` - Transaction ID (auto-generated if not provided)
    * `:dns_servers` - Request DNS servers (default: true)
  """
  @spec information_request(keyword()) :: Message.t()
  def information_request(opts) do
    duid = Keyword.fetch!(opts, :duid)

    transaction_id =
      Keyword.get(opts, :transaction_id, SecureRandom.generate_dhcpv6_transaction_id())

    dns_servers = Keyword.get(opts, :dns_servers, true)

    Message.new()
    # INFORMATION-REQUEST
    |> Map.put(:msg_type, 10)
    |> Map.put(:transaction_id, <<transaction_id::24>>)
    # CLIENTID
    |> add_option(1, duid)
    |> maybe_add_oro(dns_servers)
  end

  @doc """
  Send a DHCPv6 message to a server for testing.

  ## Options

    * `:message` - Message to send (required)
    * `:server_ip` - Server IP to send to (default: ff02::1:2)
    * `:server_port` - Server port (default: 547)
    * `:timeout` - Timeout in milliseconds (default: 5000)
  """
  @spec send_message(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def send_message(opts) do
    message = Keyword.fetch!(opts, :message)
    server_ip = Keyword.get(opts, :server_ip, {0xFF02, 0, 0, 0, 0, 0, 0x0001, 0x0002})
    server_port = Keyword.get(opts, :server_port, 547)
    timeout = Keyword.get(opts, :timeout, 5000)

    binary_message = DHCPv6.Message.to_iodata(message)

    case :gen_udp.open(0, [:binary, active: false, inet6: true]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, server_ip, server_port, binary_message)

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
  Run a complete DHCPv6 lease test cycle.

  Returns the full DHCPv6 handshake process for testing.
  """
  @spec test_lease_cycle(keyword()) ::
          {:ok,
           %{
             solicit: Message.t(),
             advertise: Message.t(),
             request: Message.t(),
             reply: Message.t()
           }}
          | {:error, term()}
  def test_lease_cycle(opts) do
    duid = Keyword.fetch!(opts, :duid)
    iaid = Keyword.fetch!(opts, :iaid)
    server_duid = Keyword.fetch!(opts, :server_duid)

    with {:ok, advertise} <- send_solicit(duid, iaid),
         {:ok, reply} <- send_request(duid, server_duid, iaid, extract_addresses(advertise)) do
      {:ok,
       %{
         solicit: solicit(duid: duid, iaid: iaid),
         advertise: advertise,
         request:
           request(
             duid: duid,
             server_duid: server_duid,
             iaid: iaid,
             addresses: extract_addresses(advertise)
           ),
         reply: reply
       }}
    end
  end

  ## Private functions

  defp send_solicit(duid, iaid) do
    message = solicit(duid: duid, iaid: iaid)
    send_message(message: message)
  end

  defp send_request(duid, server_duid, iaid, addresses) do
    message = request(duid: duid, server_duid: server_duid, iaid: iaid, addresses: addresses)
    send_message(message: message)
  end

  defp extract_addresses(message) do
    message.options
    # IA_NA
    |> Enum.filter(&(&1.option_code == 3))
    |> Enum.flat_map(fn option ->
      <<_iaid::32, _t1::32, _t2::32, rest::binary>> = option.option_data
      parse_ia_addresses(rest)
    end)
  end

  defp parse_ia_addresses(data) do
    parse_ia_addresses(data, [])
  end

  defp parse_ia_addresses(<<>>, acc), do: Enum.reverse(acc)

  defp parse_ia_addresses(
         <<5::16, option_length::16, addr_data::binary-size(option_length), rest::binary>>,
         acc
       ) do
    case parse_ipv6_address(addr_data) do
      {:ok, addr} -> parse_ia_addresses(rest, [addr | acc])
      {:error, _} -> parse_ia_addresses(rest, acc)
    end
  end

  defp parse_ia_addresses(_, acc), do: Enum.reverse(acc)

  defp parse_ipv6_address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {:ok, {a, b, c, d, e, f, g, h}}
  end

  defp parse_ipv6_address(_), do: {:error, "Invalid IPv6 address"}

  defp add_option(message, type, data) do
    option = Option.new(type, data)
    %{message | options: [option | message.options]}
  end

  defp add_ia_na(message, iaid, addresses \\ []) do
    ia_na_data = <<iaid::32, 0::32, 0::32>>

    iaaddr_options =
      Enum.map(addresses, fn addr ->
        addr_bin = ip6_to_binary(addr)
        # IAADDR option
        iaaddr_opt = Option.new(5, addr_bin)
        Option.to_iodata(iaaddr_opt)
      end)
      |> Enum.join()

    ia_na_data = <<ia_na_data::binary, iaaddr_options::binary>>
    # IA_NA option code
    add_option(message, 3, ia_na_data)
  end

  defp maybe_add_rapid_commit(message, false), do: message

  defp maybe_add_rapid_commit(message, true) do
    # RAPID_COMMIT
    add_option(message, 14, <<>>)
  end

  defp maybe_add_oro(message, false), do: message

  defp maybe_add_oro(message, true) do
    # DNS_SERVERS option code
    oro_data = <<23::16>>
    # ORO option
    add_option(message, 6, oro_data)
  end

  defp ip6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end
end
